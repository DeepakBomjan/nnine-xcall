#!/bin/bash
set -e

BINARYEN_VERS=110
BINARYEN_DWN="https://github.com/WebAssembly/binaryen/releases/download/version_${BINARYEN_VERS}/binaryen-version_${BINARYEN_VERS}-x86_64-linux.tar.gz"

WASMOPT_VERS="110"
RUSTC_VERS="1.69.0"

MAX_WASM_SIZE=800 # 800 KB

PROJECTS=("cw-xcall" "cw-xcall-lib")

# Install wasm-opt binary
if ! which wasm-opt; then
  curl -OL $BINARYEN_DWN
  tar xf binaryen-version_${BINARYEN_VERS}-x86_64-linux.tar.gz -C /tmp
  rm -f binaryen-version_*.tar.gz
  export PATH=$PATH:/tmp/binaryen-version_${BINARYEN_VERS}/bin
fi

# Check toolchain version
CUR_WASMOPT_VERS=$(wasm-opt --version | awk '{print $3}')
CUR_RUSTC_VERS=$(rustc -V | awk '{print $2}')

if [ "$CUR_RUSTC_VERS" != "$RUSTC_VERS" ] || [ "$CUR_WASMOPT_VERS" != "$WASMOPT_VERS" ]; then
  echo -e "\n ** Warning: The required versions for Rust and wasm-opt are ${RUSTC_VERS} and ${WASMOPT_VERS}, respectively. Building with different versions may result in failure.\n"
fi

mkdir -p artifacts/archway
cargo clippy --fix --allow-dirty
cargo fmt --all
cargo clean

rustup target add wasm32-unknown-unknown
cargo install cosmwasm-check@1.4.1 --locked


RUSTFLAGS='-C link-arg=-s' cargo build --workspace --exclude test-utils --release --lib --target wasm32-unknown-unknown
for WASM in ./target/wasm32-unknown-unknown/release/*.wasm; do
  NAME=$(basename "$WASM" .wasm)${SUFFIX}.wasm
  echo "Creating intermediate hash for $NAME ..."
  sha256sum -- "$WASM" | tee -a artifacts/archway/checksums_intermediate.txt
  echo "Optimizing $NAME ..."
  wasm-opt -Oz "$WASM" -o "artifacts/archway/$NAME"
done

# check all generated wasm files

cosmwasm-check  artifacts/archway/cw_mock_dapp.wasm
cosmwasm-check artifacts/archway/cw_mock_dapp_multi.wasm
cosmwasm-check  artifacts/archway/cw_xcall.wasm


# Update version
get_version() {
    if [ "$1" == "cw-xcall" ]; then
      local cargo_toml="./Cargo.toml"
    else
      local cargo_toml="contracts/cosmwasm-vm/$1/Cargo.toml"
    fi
    grep -m 1 "version" "$cargo_toml" | awk -F '"' '{print $2}'
}

# Rename filename with version in it
rename_wasm_with_version() {
    local project_path="$1"
    local version=$(get_version "$project_path")
    local wasm_file="artifacts/archway/${project_path//-/_}.wasm"
    echo $project_path
    echo $version
    echo $wasm_file
    if [[ -f "$wasm_file" ]]; then
        cp "$wasm_file" "${wasm_file%.wasm}_latest.wasm"
        mv "$wasm_file" "${wasm_file%.wasm}_${version}.wasm"
        echo "Renamed: ${wasm_file} -> ${wasm_file%.wasm}_${version}.wasm"
    else
        echo "Error: Wasm file not found: $wasm_file"
    fi
}

# Loop through each project and rename wasm files
for project in "${PROJECTS[@]}"; do
    rename_wasm_with_version "$project"
done


# validate size
echo "Check if size of wasm file exceeds $MAX_WASM_SIZE kilobytes..."
for file in artifacts/archway/*.wasm
do
size=$(du -k "$file" | awk '{print $1}')
if [ $size -gt $MAX_WASM_SIZE ]; then
echo "Error: $file : $size KB has exceeded maximum contract size limit of $MAX_WASM_SIZE KB."
exit 1
fi
echo "$file : $size KB"
done
echo "The size of all contracts is well within the $MAX_WASM_SIZE KB limit."
