#!/bin/bash

ffmpeg -i "$1" -i tests/ccpal.png -filter_complex "[0][1]paletteuse" "$2"