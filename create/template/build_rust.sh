#!/usr/bin/env bash

cd rust/glue

if [ "$1" = "Release" ]
then
    ARG="--release"
else
    ARG=""
fi

if [ ! -f ~/.cargo/bin/cargo-lipo ]; then
    ~/.cargo/bin/cargo install cargo-lipo
fi

~/.cargo/bin/cargo lipo $ARG