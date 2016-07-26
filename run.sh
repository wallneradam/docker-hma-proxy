#!/bin/bash

docker run -ti --name hma \
    --env-file $PWD/hma.env \
    --privileged --rm -p 8888:8888 \
    -v $PWD:/opt \
    pickapp/hma-proxy:1.10.1
