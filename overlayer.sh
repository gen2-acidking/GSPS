#!/bin/bash
# Don't use yet just testing

set -euo pipefail


GSPS_ROOT="$(pwd)"
OVERLAY_DIR="${GSPS_ROOT}/overlays/acidking"

mkdir -p "$OVERLAY_DIR/profiles" "$OVERLAY_DIR/metadata"
echo "acidking" > "$OVERLAY_DIR/profiles/repo_name"

cat <<EOF > "$OVERLAY_DIR/metadata/layout.conf"
masters = gentoo
auto-sync = no
EOF

declare -A packages=(
  ["x11-wm/dwmconf"]="https://github.com/gen2-acidking/dwmconf.git"
  ["x11-terms/based-alacritty-theme"]="https://github.com/gen2-acidking/based_alacritty_theme.git"
  ["app-editors/based-vscode-theme"]="https://github.com/gen2-acidking/based_vscode_theme.git"
  ["app-editors/based-theme-nvim"]="https://github.com/gen2-acidking/based_theme.nvim.git"
  ["app-editors/nvim-l-ed"]="https://github.com/gen2-acidking/Nvim-L-ed.git"
  ["app-misc/kefir"]="https://github.com/gen2-acidking/kefir.git"
  ["sys-apps/smol-utils"]="https://github.com/gen2-acidking/smol_utils.git"
)

for cp in "${!packages[@]}"; do
  cat=${cp%%/*}
  pkg=${cp##*/}
  mkdir -p "$OVERLAY_DIR/$cat/$pkg"
  EB="$OVERLAY_DIR/$cat/$pkg/${pkg}-9999.ebuild"

  cat <<EOEBUILD > "$EB"
EAPI=8

inherit git-r3

DESCRIPTION="$pkg from user overlay"
HOMEPAGE="${packages[$cp]}"
EGIT_REPO_URI="${packages[$cp]}"

LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64"
IUSE=""

RDEPEND=""
DEPEND="\${RDEPEND}"

src_install() {
  einstalldocs
  insinto /opt/$pkg
  doins -r .
}
EOEBUILD

  (cd "$OVERLAY_DIR/$cat/$pkg" && ebuild "${pkg}-9999.ebuild" manifest || true)
done

echo "Overlay initialized at $OVERLAY_DIR"
echo "Add it to /etc/portage/repos.conf if not already."
