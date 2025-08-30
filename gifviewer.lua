local box = require("pixelbox_lite").new(term.current())
local gif = require "gif"

local args = {...}

local progress = 0
local vid, err = gif.load(args[1], 100, function()
    term.setCursorPos(1, 1)
    term.write("Progress: " .. tostring(progress))
    progress = progress + 100
end)

if vid then
    local frame = 1
    while 1 do
        local img = vid.dataimages[frame]
        local palette = true and img.localColorTable or vid.globalColorTable
        for x=0,(#palette-1)%16 do
            term.setPaletteColor(2^x, palette[x+1][1]/255, palette[x+1][2]/255, palette[x+1][3]/255)
        end
        
        local start = os.epoch("utc")
        for x=0,img.width-1 do
            for y=0,img.height-1 do
                local pix = img.data[x + y * img.width + 1]

                if not (img.transparencyFlag and (pix==img.transparencyIndex)) then
                    box.canvas[y+img.top+1][x+img.left+1] = 2^(pix%16)
                end
            end
        end

        box:render()
        if img.disposalMethod==2 then
            for x=1,vid.canvasWidth do
                for y=1,vid.canvasHeight do
                    box.canvas[y][x] = 2^(vid.backgroundColorIndex%16)
                end
            end
        end
        local dif = os.epoch("utc")-start
        sleep(img.delayTime / 100 - dif / 1000)
        frame = frame + 1 
        if frame>#vid.dataimages then frame = 1 end
    end
else
    print(err)
end