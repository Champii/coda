cd

yay -S git curl

git clone https://github.com/Champii/coda.git
cd coda
git checkout master-merge

cp ../setup/.gitconfig .git/config
cp ../setup/.gitmodules .gitmodules

git submodule init && git submodule update --recursive

yay -Syu && yay -S \
    cmake \
    jq \
    boost-libs \
    boost \
    libffi-dev \
    libgmp-static \
    procps-ng \
    libsodium \
    openssl \
    lsb \
    m4 \
    pandoc \
    patchelf \
    python \
    perl \
    pkg-config \
    rubygems \
    zlib \
    rocksdb \
    unzip \
    rsync \
    bubblewrap
    # python-jinja2 \
    # libgmp-dev \
    # libgmp3-dev \
    # ow-libbz2

curl https://nixos.org/nix/install | sh

# export CLOUD_SDK_REPO="cloud-sdk-$(lsb_release -c -s)" && \
#     echo "deb http://packages.cloud.google.com/apt $CLOUD_SDK_REPO main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
#     curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add - && \
#     sudo apt-get update -y && sudo apt-get install google-cloud-sdk -y

cd
git clone https://github.com/ocaml/opam.git
cd opam
make cold CONFIGURE_ARGS="--prefix ~/local"
make cold-install

# source ~/.bashrc

# git clone https://github.com/facebook/rocksdb -b v5.17.2 ../rocksdb
# cd ../rocksdb
# sudo make static_lib PORTABLE=1 -j$(nproc) && sudo cp librocksdb.a /usr/local/lib/librocksdb_coda.a && sudo rm -rf /rocksdb && sudo strip -S /usr/local/lib/librocksdb_coda.a

sudo ln -s ~/local/bin/opam /usr/bin/opam

cd
opam init --yes

eval $(opam env)

opam update -y && opam upgrade -y


cd coda
cp src/opam.export .
opam switch --unlock-base --yes import opam.export ; rm opam.export

opam pin --yes add src/external/digestif
opam pin --yes add src/external/async_kernel
# opam pin --yes add src/external/ocaml-sodium
opam pin --yes add src/external/rpc_parallel
opam pin --yes add src/external/ocaml-extlib
opam pin --yes add src/external/coda_base58

make build
make kademlia

sudo ln -sf /usr/share/zoneinfo/UTC /etc/localtime
