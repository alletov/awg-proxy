#!/usr/bin/env bash

update_project() (
  require_root
  [[ $SCRIPT_DIR == /opt/awgproxy ]] || die "update is available for an installed AWG Proxy"
  [[ -d $SCRIPT_DIR/lib && ! -L $SCRIPT_DIR/lib ]] || die "invalid installed library directory"
  local repo=alletov/awg-proxy branch=main
  local -a source=()
  if [[ -r $SCRIPT_DIR/update-source ]]; then
    mapfile -t source < "$SCRIPT_DIR/update-source"
    (( ${#source[@]} == 2 )) || die "invalid update-source file"
    repo=${source[0]}
    branch=${source[1]}
  fi
  [[ $repo =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$ && $repo != */. && $repo != */.. ]] ||
    die "invalid GitHub repository: $repo"
  [[ $branch =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ && $branch != *..* && $branch != . && $branch != */. && $branch != ./* && $branch != */./* ]] ||
    die "invalid GitHub branch: $branch"

  local lock_fd
  exec {lock_fd}>"$SCRIPT_DIR/.update.lock"
  flock -n "$lock_fd" || die "another update is in progress"

  local work backup='' applying=0 file archive_root target_version
  local -a files=(awgproxy.sh version) changed=()
  work=$(mktemp -d "$SCRIPT_DIR/.update.XXXXXXXX")
  trap '
    if (( applying )); then
      warn "restoring previous scripts after an interrupted update"
      for file in "${changed[@]}"; do
        if [[ -f $backup/$file ]]; then
          cp -a -- "$backup/$file" "$SCRIPT_DIR/$file" || warn "could not restore $file"
        else
          rm -f -- "$SCRIPT_DIR/$file" || warn "could not remove $file"
        fi
      done
    fi
    rm -rf -- "$work"
  ' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  info "Downloading $repo ($branch) from GitHub"
  curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 60 --max-filesize 10485760 \
    "https://github.com/$repo/archive/refs/heads/$branch.tar.gz" -o "$work/source.tar.gz"
  tar -tzf "$work/source.tar.gz" > "$work/members"
  archive_root=$(awk '/^[A-Za-z0-9_.-]+\/awgproxy\.sh$/ { sub(/\/awgproxy\.sh$/, ""); print }' "$work/members")
  [[ $archive_root =~ ^[A-Za-z0-9_.-]+$ && $archive_root != . && $archive_root != .. ]] ||
    die "invalid AWG Proxy archive"

  local member root lib_file
  while IFS= read -r member; do
    if [[ $member =~ ^([A-Za-z0-9_.-]+)/lib/([A-Za-z0-9_-]+\.sh)$ ]]; then
      root=${BASH_REMATCH[1]}
      lib_file=${BASH_REMATCH[2]}
      if [[ $root == "$archive_root" ]]; then files+=("lib/$lib_file"); fi
    fi
  done < "$work/members"

  mkdir -p "$work/new/lib"
  for file in "${files[@]}"; do
    [[ ! -e $work/new/$file ]] || die "duplicate archive entry: $file"
    tar -xOzf "$work/source.tar.gz" -- "$archive_root/$file" > "$work/new/$file"
    [[ -s $work/new/$file ]] || die "empty archive entry: $file"
    if [[ $file == *.sh ]]; then bash -n "$work/new/$file"; fi
    if [[ -L $SCRIPT_DIR/$file || ( -e $SCRIPT_DIR/$file && ! -f $SCRIPT_DIR/$file ) ]]; then
      die "unexpected installed path: $file"
    fi
    if ! cmp -s "$work/new/$file" "$SCRIPT_DIR/$file"; then changed+=("$file"); fi
  done
  for file in common detect config render actions update; do
    [[ -f $work/new/lib/$file.sh ]] || die "incomplete archive: lib/$file.sh"
  done
  target_version=$(<"$work/new/version")
  [[ $target_version =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$ ]] ||
    die "invalid version in archive"
  if (( ${#changed[@]} == 0 )); then
    ok "AWG Proxy $VERSION is already up to date"
    return 0
  fi

  printf 'GitHub: %s (%s)\nВерсия: %s → %s\nФайлов к обновлению: %s\n' \
    "$repo" "$branch" "$VERSION" "$target_version" "${#changed[@]}"
  if ! confirm "Установить обновление?"; then
    info "обновление отменено"
    return 0
  fi

  install -d -m 0700 "$BACKUP_DIR"
  backup=$(mktemp -d "$BACKUP_DIR/scripts-before-update.XXXXXXXX")
  mkdir "$backup/lib"
  for file in "${changed[@]}"; do
    if [[ -f $SCRIPT_DIR/$file ]]; then cp -a -- "$SCRIPT_DIR/$file" "$backup/$file"; fi
    if [[ $file == awgproxy.sh ]]; then chmod 0755 "$work/new/$file"; else chmod 0644 "$work/new/$file"; fi
  done
  info "Резервная копия скриптов: $backup"
  applying=1
  # Publish the entry point after its supporting modules.
  for file in "${changed[@]}"; do
    if [[ $file != awgproxy.sh ]]; then mv -T -- "$work/new/$file" "$SCRIPT_DIR/$file"; fi
  done
  if [[ -f $work/new/awgproxy.sh ]] && ! cmp -s "$work/new/awgproxy.sh" "$SCRIPT_DIR/awgproxy.sh"; then
    mv -T -- "$work/new/awgproxy.sh" "$SCRIPT_DIR/awgproxy.sh"
  fi
  applying=0
  ok "AWG Proxy $target_version обновлён"
)
