#!/bin/bash

ffmpeg -i "$1" -vf "palettegen=max_colors=16" palette.png
ffmpeg -i "$1" -i palette.png -filter_complex "[0][1]paletteuse" "$2"