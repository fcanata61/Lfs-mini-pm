#!/bin/sh
# lfs-mini-pm.sh — gerenciador mínimo de build/empacotamento para LFS
# POSIX sh, zero magia: usa curl, git, tar, unzip, fakeroot.
# Funciona com recipes locais (arquivos .recipe = shell) e empacota em tar.
#
# Requisitos mínimos (em PATH):
#   sh (POSIX), curl, tar, fakeroot
# Opcionais: git, unzip, xz, bzip2, gzip, sha256sum, patch, make, cc
#
# Uso rápido:
#   ./lfs-mini-pm.sh init
#   ./lfs-mini-pm.sh new foo 1.0 "https://exemplo.org/foo-1.0.tar.gz"
#   ./lfs-mini-pm.sh build foo   # baixa, extrai, compila, instala em DESTDIR e gera pacote
#   ./lfs-mini-pm.sh installpkg foo-1.0-<arq>.tar.gz   # instala pacote (extrai em /)
#   ./lfs-mini-pm.sh search foo
#   ./lfs-mini-pm.sh info foo
#   Variáveis podem ser sobrescritas por ambiente ou flags (-s, -w, -r, -p, -L...)
#
# Formato de recipe (arquivo recipes/NOME.recipe):
#   NAME=foo
#   VERSION=1.0
#   URL="https://exemplo.org/foo-1.0.tar.gz"  # ou GIT="https://...git"
#   # SHA256 opcional: SHA256="<hash>"
#   # DEPENDS é ignorado (sem gestão de dependências por design), apenas informativo
#   DEPENDS=""
#   # PREFIX padrão /usr; pode ajustar FLAGS de build
#   PREFIX=${PREFIX:-/usr}
#   configure() { ./configure --prefix="$PREFIX" "$@"; }
#   build()     { make -j${JOBS}; }
#   install()   { make DESTDIR="$DESTDIR" install; }
#   # (todas as funções/variáveis são opcionais; há defaults no script)
#
# Licença: CC0 / domínio público. Sem garantias.

set -eu
umask 022

# ======= Configuração (tudo em variáveis, sobrescrevível por env/flags) =======
PREFIX=${PREFIX:-/usr}
ROOT_DIR=${ROOT_DIR:-$(pwd)}
SOURCE=${SOURCE:-"$ROOT_DIR/sources"}
WORKDIR=${WORKDIR:-"$ROOT_DIR/work"}
BUILD=${BUILD:-"$ROOT_DIR/build"}
DESTBASE=${DESTBASE:-"$ROOT_DIR/dest"}
PKGDIR=${PKGDIR:-"$ROOT_DIR/packages"}
LOGDIR=${LOGDIR:-"$ROOT_DIR/logs"}
RECIPES=${RECIPES:-"$ROOT_DIR/recipes"}
REGISTRY=${REGISTRY:-"$ROOT_DIR/registry.txt"}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
COLOR=${COLOR:-auto}    # auto|always|never
QUIET=${QUIET:-0}
VERBOSE=${VERBOSE:-0}
SPINNER=${SPINNER:-1}
PKG_COMPRESSION=${PKG_COMPRESSION:-gz}  # gz|xz|bz2|zst (zstd se presente via zstd)
PKG_OWNER=${PKG_OWNER:-root}
PKG_GROUP=${PKG_GROUP:-root}
PKG_MODE=${PKG_MODE:-0644}

# ======= TTY/cores =======
_is_tty() { [ -t 1 ]; }
_color() {
  case "$COLOR" in
    always) : ;;
    never) return 0 ;;
    auto) _is_tty || return 0 ;;
  esac
  case "$1" in
    red)   printf '\033[31m' ;;
    green) printf '\033[32m' ;;
    yellow)printf '\033[33m' ;;
    blue)  printf '\033[34m' ;;
    mag)   printf '\033[35m' ;;
    cyan)  printf '\033[36m' ;;
    bold)  printf '\033[1m'  ;;
    reset) printf '\033[0m'  ;;
  esac
}
log() {
  [ "$QUIET" -eq 1 ] && return 0
  _color cyan; printf "[lfs] "; _color reset; printf "%s\n" "$*"
}
warn() { _color yellow; printf "[warn] %s\n" "$*"; _color reset; }
err()  { _color red; printf "[err ] %s\n" "$*"; _color reset; }
ok()   { _color green; printf "[ ok ] %s\n" "$*"; _color reset; }

# ======= Spinner =======
show_spinner() {
  pid=$1; msg=$2
  [ "$SPINNER" -eq 0 ] && { wait "$pid"; return $?; }
  chars='|/-\\'
  i=0
  while kill -0 "$pid" 2>/dev/null; do
    c=$(printf %s "$chars" | cut -c $((i%4+1)))
    printf "\r%s %s" "$c" "$msg"
    i=$((i+1))
    sleep 0.1
  done
  wait "$pid"; rc=$?
  printf "\r    %s\n" "$msg"
  return "$rc"
}

# ======= Util =======
need() { command -v "$1" >/dev/null 2>&1 || { err "Comando requerido não encontrado: $1"; exit 1; }; }
mtime() { ls -ld "$1" 2>/dev/null | awk '{print $6" "$7" "$8}'; }

mkdirs() { mkdir -p "$SOURCE" "$WORKDIR" "$BUILD" "$DESTBASE" "$PKGDIR" "$LOGDIR" "$RECIPES"; }

_fetch() {
  url=$1; out=$2
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --progress-bar -o "$out" "$url"
  else
    err "curl é necessário para download"; exit 1
  fi
}
_git_clone_or_update() {
  repo=$1; dest=$2
  if command -v git >/dev/null 2>&1; then
    if [ -d "$dest/.git" ]; then
      git -C "$dest" fetch --all --tags --prune && git -C "$dest" reset --hard origin/HEAD 2>/dev/null || git -C "$dest" pull --rebase
    else
      git clone --depth 1 "$repo" "$dest"
    fi
  else
    err "git não encontrado para clonar $repo"; exit 1
  fi
}

_extract() {
  src=$1; dest=$2
  mkdir -p "$dest"
  case "$src" in
    *.tar.gz|*.tgz)      tar -xzf "$src" -C "$dest" ;;
    *.tar.xz)            tar -xJf "$src" -C "$dest" ;;
    *.tar.bz2|*.tbz2)    tar -xjf "$src" -C "$dest" ;;
    *.tar.zst)           command -v zstd >/dev/null 2>&1 || { err "zstd requerido p/ .zst"; exit 1; }; zstd -d <"$src" | tar -x -C "$dest" ;;
    *.zip)               need unzip; unzip -q "$src" -d "$dest" ;;
    *.tar)               tar -xf "$src" -C "$dest" ;;
    *) err "Formato não suportado: $src"; exit 1 ;;
  esac
}

_pkg_mkname() {
  name=$1; ver=$2
  printf "%s-%s" "$name" "$ver"
}

_pkg_compress_args() {
  case "$PKG_COMPRESSION" in
    gz)  echo "-z" ;;
    xz)  echo "-J" ;;
    bz2) echo "-j" ;;
    zst) command -v zstd >/dev/null 2>&1 || { err "zstd não encontrado"; exit 1; }; echo "--zstd" ;;
    *)   echo "-z" ;;
  esac
}

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "" # sem verificação
  fi
}

_registry_add() { printf "%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$(date -u +%FT%TZ)" >> "$REGISTRY"; }

# ======= Recipes =======
recipe_path() { printf "%s/%s.recipe" "$RECIPES" "$1"; }
ensure_recipe() { [ -f "$(recipe_path "$1")" ] || { err "Recipe não encontrada: $1"; exit 1; }; }

# ======= Defaults de build =======
_default_configure() { ./configure --prefix="$PREFIX" ; }
_default_build()     { make -j"$JOBS" ; }
_default_install()   { make DESTDIR="$DESTDIR" install ; }

# ======= Alvo: init =======
cmd_init() {
  mkdirs
  touch "$REGISTRY"
  ok "Estrutura criada em: $ROOT_DIR"
  log "sources=$(mtime "$SOURCE") | recipes=$(mtime "$RECIPES")"
}

# ======= Alvo: new NOME VERSAO URL [SHA256] =======
cmd_new() {
  name=$1; ver=$2; url=${3:-}; sha=${4:-}
  mkdirs
  f=$(recipe_path "$name")
  [ -e "$f" ] && { err "Já existe recipe: $f"; exit 1; }
  {
    printf "NAME=%s\n" "$name"
    printf "VERSION=%s\n" "$ver"
    [ -n "$url" ] && printf "URL=\"%s\"\n" "$url"
    [ -n "$sha" ] && printf "SHA256=\"%s\"\n" "$sha"
    printf "PREFIX=\"\${PREFIX:-/usr}\"\n"
    cat <<'EOF'
# DEPENDS é apenas informativo (sem gestão automática por design)
DEPENDS=""
configure() { ./configure --prefix="$PREFIX" "$@"; }
build()     { make -j${JOBS}; }
install()   { make DESTDIR="$DESTDIR" install; }
EOF
  } > "$f"
  ok "Recipe criada: $f"
}

# ======= Alvo: fetch NOME =======
cmd_fetch() {
  name=$1; ensure_recipe "$name"; . "$(recipe_path "$name")"
  mkdirs
  if [ -n "${GIT-}" ]; then
    dest="$SOURCE/$NAME-$VERSION.git"
    (_git_clone_or_update "$GIT" "$dest") & pid=$!; show_spinner "$pid" "git fetch $NAME" || exit 1
    SRC_KIND=git; SRC_PATH="$dest"
  elif [ -n "${URL-}" ]; then
    base=$(basename "$URL")
    out="$SOURCE/$base"
    [ -f "$out" ] || { (_fetch "$URL" "$out") & pid=$!; show_spinner "$pid" "baixando $base" || exit 1; }
    if [ -n "${SHA256-}" ]; then
      got=$(_sha256 "$out")
      [ "x$got" = "x$SHA256" ] || { err "SHA256 incorreto para $base"; exit 1; }
    fi
    SRC_KIND=tarball; SRC_PATH="$out"
  else
    err "Recipe precisa de URL ou GIT"; exit 1
  fi
  printf "%s\n" "$SRC_KIND:$SRC_PATH"
}

# ======= Alvo: extract NOME =======
cmd_extract() {
  name=$1; ensure_recipe "$name"; . "$(recipe_path "$name")"
  mkdirs
  work="$WORKDIR/$NAME-$VERSION"
  rm -rf "$work"; mkdir -p "$work"
  if [ -n "${GIT-}" ]; then
    dest="$SOURCE/$NAME-$VERSION.git"
    _git_clone_or_update "$GIT" "$dest"
    (cp -a "$dest"/. "$work"/) & pid=$!; show_spinner "$pid" "copiando git $NAME" || exit 1
    srcdir="$work"
  else
    base=${URL##*/}
    tarball="$SOURCE/$base"
    _extract "$tarball" "$work"
    # entrar no único diretório se existir
    sub=$(ls -1 "$work" | wc -l || true)
    if [ "$sub" -eq 1 ]; then
      d=$(ls -1 "$work")
      srcdir="$work/$d"
    else
      srcdir="$work"
    fi
  fi
  printf "%s\n" "$srcdir"
}

# ======= Alvo: build NOME =======
cmd_build() {
  name=$1; ensure_recipe "$name"; . "$(recipe_path "$name")"
  mkdirs
  logf="$LOGDIR/$NAME-$VERSION.build.log"
  : > "$logf"
  log "Iniciando build de $NAME-$VERSION (log: $logf)"

  # FETCH
  cmd_fetch "$name" >>"$logf" 2>&1

  # EXTRACT
  srcdir=$(cmd_extract "$name")

  # BUILD dir separado
  bdir="$BUILD/$NAME-$VERSION"
  rm -rf "$bdir"; mkdir -p "$bdir"

  DESTDIR="$DESTBASE/$NAME-$VERSION/root"
  rm -rf "$DESTDIR"; mkdir -p "$DESTDIR"

  # Aplicar patches se a recipe fornecer diretório patches/
  if [ -d "$RECIPES/$NAME.patches" ]; then
    for p in "$RECIPES/$NAME.patches"/*.patch; do
      [ -e "$p" ] || break
      (cd "$srcdir" && patch -p1 < "$p") >>"$logf" 2>&1 || { err "Falha em patch $p"; exit 1; }
    done
  fi

  # Configure/build/install (com defaults)
  (
    set -e
    cd "$bdir"
    if [ -x "$srcdir/configure" ] || command -v configure >/dev/null 2>&1; then
      if command -v configure >/dev/null 2>&1; then
        configure "--prefix=$PREFIX"
      elif command -v sh >/dev/null 2>&1 && [ -x "$srcdir/configure" ]; then
        cd "$srcdir" && { command -v configure >/dev/null 2>&1 || configure() { ./configure --prefix="$PREFIX" "$@"; }; cd - >/dev/null
        cd "$bdir"; "$srcdir"/configure --prefix="$PREFIX"
      fi
    fi
    # caso recipe defina configure()
    if command -v configure >/dev/null 2>&1; then
      (cd "$srcdir" && configure --prefix="$PREFIX")
    elif type configure 2>/dev/null | grep -q function; then
      (cd "$srcdir"; configure --prefix="$PREFIX")
    else
      :
    fi

    # build
    if type build 2>/dev/null | grep -q function; then
      (cd "$srcdir"; build)
    else
      (cd "$srcdir"; _default_build)
    fi

    # install sob fakeroot
    if type install 2>/dev/null | grep -q function; then
      fakeroot sh -c 'cd "$0"; DESTDIR="$1" install' "$srcdir" "$DESTDIR"
    else
      fakeroot sh -c 'cd "$0"; DESTDIR="$1" make install' "$srcdir" "$DESTDIR"
    fi
  ) >>"$logf" 2>&1 & pid=$!
  show_spinner "$pid" "compilando $NAME-$VERSION" || { err "Build falhou (veja $logf)"; exit 1; }

  # Criar pacote tar do DESTDIR
  pkgname=$(_pkg_mkname "$NAME" "$VERSION")
  pkgroot="$DESTBASE/$NAME-$VERSION/root"
  comp=$(_pkg_compress_args)
  (cd "$pkgroot" && tar $comp -cpf "$PKGDIR/$pkgname.tar.$PKG_COMPRESSION" .) || { err "Falha ao empacotar"; exit 1; }
  ok "Pacote criado: $PKGDIR/$pkgname.tar.$PKG_COMPRESSION"

  # Registrar
  _registry_add "$NAME" "$VERSION" "$PKGDIR/$pkgname.tar.$PKG_COMPRESSION"
  ok "Registrado em $REGISTRY"
}

# ======= Alvo: info NOME =======
cmd_info() {
  name=$1; ensure_recipe "$name"; . "$(recipe_path "$name")"
  printf "Name: %s\nVersion: %s\n" "$NAME" "$VERSION"
  [ -n "${URL-}" ] && printf "URL: %s\n" "$URL"
  [ -n "${GIT-}" ] && printf "GIT: %s\n" "$GIT"
  [ -n "${DEPENDS-}" ] && printf "DEPENDS: %s\n" "$DEPENDS"
}

# ======= Alvo: list/search =======
cmd_list()   { ls -1 "$RECIPES"/*.recipe 2>/dev/null | sed 's#.*/##;s#\.recipe$##' || true; }
cmd_search() { pat=$1; cmd_list | grep -i "$pat" || true; }

# ======= Alvo: installpkg ARQUIVO (extrai no /) =======
cmd_installpkg() {
  pkg=$1
  need tar
  log "Instalando pacote em / (requer privilégios conforme sistema)"
  fakeroot sh -c 'tar -xpf "$0" -C /' "$pkg"
  ok "Instalado: $pkg"
}

# ======= Alvo: clean NOME|all =======
cmd_clean() {
  target=${1:-}
  if [ "$target" = "all" ]; then
    rm -rf "$WORKDIR" "$BUILD" "$DESTBASE"
    ok "Limpeza completa de diretórios temporários"
  else
    name=$target; ensure_recipe "$name"; . "$(recipe_path "$name")"
    rm -rf "$WORKDIR/$NAME-$VERSION" "$BUILD/$NAME-$VERSION" "$DESTBASE/$NAME-$VERSION"
    ok "Limpeza de $NAME-$VERSION"
  fi
}

# ======= Ajuda =======
usage() {
  cat <<EOF
Uso: ${0##*/} [OPÇÕES] COMANDO [ARGS]

Opções (curtas):
  -s DIR   SOURCE (default: $SOURCE)
  -w DIR   WORKDIR (default: $WORKDIR)
  -b DIR   BUILD (default: $BUILD)
  -d DIR   DEST base (default: $DESTBASE)
  -p DIR   PKGDIR (default: $PKGDIR)
  -L DIR   LOGDIR (default: $LOGDIR)
  -r DIR   RECIPES (default: $RECIPES)
  -R FILE  REGISTRY (default: $REGISTRY)
  -j N     JOBS (default: $JOBS)
  -C MODE  COLOR: auto|always|never (default: $COLOR)
  -q       QUIET
  -v       VERBOSE
  -S       desativa spinner
  -h       ajuda

Comandos:
  init                      cria estrutura de diretórios e registry
  new NAME VER URL [SHA]    cria recipe mínima
  fetch NAME                baixa fonte (curl/git)
  extract NAME              descompacta para diretório de trabalho
  build NAME                compila, instala com DESTDIR+fakeroot e empacota
  info NAME                 mostra infos da recipe
  list                      lista recipes
  search PATTERN            procura por nome de recipe
  installpkg ARQ.tar.*      instala pacote no sistema (tar -xpf /)
  clean NAME|all            remove diretórios temporários

Exemplos:
  ${0##*/} -r ./recipes -p ./pkgs build zlib
  PREFIX=/usr/local ${0##*/} build mytool
EOF
}

# ======= Parse flags (getopts POSIX) =======
while getopts "s:w:b:d:p:L:r:R:j:C:qvSh" opt; do
  case "$opt" in
    s) SOURCE=$OPTARG ;;
    w) WORKDIR=$OPTARG ;;
    b) BUILD=$OPTARG ;;
    d) DESTBASE=$OPTARG ;;
    p) PKGDIR=$OPTARG ;;
    L) LOGDIR=$OPTARG ;;
    r) RECIPES=$OPTARG ;;
    R) REGISTRY=$OPTARG ;;
    j) JOBS=$OPTARG ;;
    C) COLOR=$OPTARG ;;
    q) QUIET=1 ;;
    v) VERBOSE=1 ;;
    S) SPINNER=0 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND-1))

[ $# -gt 0 ] || { usage; exit 1; }
cmd=$1; shift || true

case "$cmd" in
  init)        cmd_init "$@" ;;
  new)         [ $# -ge 2 ] || { err "new NAME VERSION [URL]"; exit 1; }; cmd_new "$@" ;;
  fetch)       [ $# -eq 1 ] || { err "fetch NAME"; exit 1; }; cmd_fetch "$@" ;;
  extract)     [ $# -eq 1 ] || { err "extract NAME"; exit 1; }; cmd_extract "$@" ;;
  build)       [ $# -eq 1 ] || { err "build NAME"; exit 1; }; cmd_build "$@" ;;
  info)        [ $# -eq 1 ] || { err "info NAME"; exit 1; }; cmd_info "$@" ;;
  list)        cmd_list ;;
  search)      [ $# -eq 1 ] || { err "search PATTERN"; exit 1; }; cmd_search "$@" ;;
  installpkg)  [ $# -eq 1 ] || { err "installpkg ARQUIVO"; exit 1; }; cmd_installpkg "$@" ;;
  clean)       [ $# -ge 1 ] || { err "clean NAME|all"; exit 1; }; cmd_clean "$@" ;;
  *)           err "Comando desconhecido: $cmd"; usage; exit 1 ;;
esac
