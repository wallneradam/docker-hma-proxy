#!/bin/bash

docker run --rm -ti --name hma \
    --env-file $PWD/config/hma.env \
    --privileged --rm \
    -p 8888:8888 \
    -v $PWD:/opt \
    pickapp/hma-proxy:1.2
