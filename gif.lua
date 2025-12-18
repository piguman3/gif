local gif = {}

local function consume(stream, count)
    local res = stream.str:sub(stream.head, stream.head+count-1)
    stream.head = stream.head + count

    return res
end

local function seek(stream, count)
    stream.head = stream.head + count
end

local function consumeInt(stream, count)
    local intStr = consume(stream, count)
    local int = 0

    for x=1,count do
        int = int + bit32.lshift(intStr:sub(x,x):byte(), (x-1)*8)
    end

    return int
end

local function consume8(stream, count)
    local res = {stream.str:byte(math.floor(stream.head / 8) + 1, math.ceil((stream.head + count) / 8))}
    local num = 0
    for x,byte in pairs(res) do
        num = num + bit32.lshift(byte, (x-1)*8)
    end
    local out = bit32.extract(num, stream.head%8, count)

    stream.head = stream.head + count
    return out
end

local function seek8(stream, count)
    stream.head = stream.head + count
end

-- Returns color table as RGB pairs inside of their own tables
local function consumeColorTable(stream, size)
    local colorTable = {}

    for x=1,size do
        colorTable[x] = {consume(stream, 1):byte(), consume(stream, 1):byte(), consume(stream, 1):byte()}
    end

    return colorTable
end

local function seekAllBlocks(stream)
    while 1 do
        local blockSize = consume(stream, 1):byte()
        if blockSize==0 then break end
        seek(stream, blockSize)
    end
end

local function consumeAllBlocks(stream)
    local res = ""
    while 1 do
        local blockSize = consume(stream, 1):byte()
        if blockSize==0 then break end
        res = res .. consume(stream, blockSize)
    end
    return res
end

local function consumeImageData(stream, out, image)
    local minCodeSize = consume(stream, 1):byte()

    local clearCode = 2^minCodeSize
    local endCode = clearCode + 1

    local dataStream = {str="", head=0}

    dataStream.str = consumeAllBlocks(stream)

    -- Extract codes from data
    -- TESTING
    local codeStream = {}
    
    local codeSize = minCodeSize + 1
    local nextPower = 2^codeSize
    
    local function getNextCode(codeSize)
        local code = consume8(dataStream, codeSize)

        return code
    end

    local codeTable = {}

    -- Setup code table
    local function clear()
        codeTable = {}
        codeSize = minCodeSize + 1
        nextPower = 2^codeSize
        for x=0,2^minCodeSize+1 do
            codeTable[x] = {x}
        end
    end
    clear()
    
    local indexTable = {}
    local firstIndex

    getNextCode(codeSize) -- Ignore first clear
    local prevCode = getNextCode(codeSize)
    table.insert(indexTable, prevCode) -- Output first code to index stream
    while 1 do
        local code = getNextCode(codeSize)

        if (code==endCode) or (code==nil) then
            break
        end

        if code==clearCode then
            clear()
            prevCode = getNextCode(codeSize)
            table.insert(indexTable, prevCode)
        else 
            if codeTable[code] then
                for k,v in pairs(codeTable[code]) do
                    table.insert(indexTable, v)
                end
                codeTable[#codeTable+1] = {}
                for k,v in pairs(codeTable[prevCode]) do
                    codeTable[#codeTable][k] = v
                end
                table.insert(codeTable[#codeTable], codeTable[code][1])
            else
                codeTable[code] = {}
                for k,v in pairs(codeTable[prevCode]) do
                    codeTable[code][k] = v
                end
                table.insert(codeTable[code], codeTable[prevCode][1])
                for k,v in pairs(codeTable[code]) do
                    table.insert(indexTable, v)
                end
            end
            prevCode = code
        end

        if (#codeTable==nextPower-1) and (nextPower<0x1000) then
            codeSize = codeSize + 1
            nextPower = 2^codeSize
        end
    end

    image.data = indexTable
end

local lastGCE -- Set by Graphics Control Extension, consumed and set to nil by images

local segments = {
    -- IMAGES
    [","] = function(stream, out)
        local image = {}

        if lastGCE then
            for k,v in pairs(lastGCE) do -- Copy over data from image's GCE
                image[k] = v
            end
            lastGCE = nil
        end

        image.left = consumeInt(stream, 2)
        image.top = consumeInt(stream, 2)

        image.width = consumeInt(stream, 2)
        image.height = consumeInt(stream, 2)

        local packedField = consume(stream, 1):byte()

        -- Local Color Table
        local localTableFlag = bit32.extract(packedField, 7, 1)==1
        local localTableSize = 2 ^ (bit32.extract(packedField, 0, 3) + 1)

        if localTableFlag then
            image.localColorTable = consumeColorTable(stream, localTableSize)
        end

        consumeImageData(stream, out, image)

        table.insert(out.dataimages, image)

        sleep()
    end,

    -- EXTENSIONS --

    -- Graphics Control Extension
    ["!" .. string.char(0xF9)] = function(stream, out)
        local dataStream = {str=consumeAllBlocks(stream), head=1}

        lastGCE = {} -- Data the next image will use

        local packed = consume(dataStream, 1):byte()
        lastGCE.disposalMethod = bit32.extract(packed, 2, 3)
        lastGCE.transparencyFlag = bit32.extract(packed, 0, 1)==1
        lastGCE.delayTime = consumeInt(dataStream, 2)
        lastGCE.transparencyIndex = consume(dataStream, 1):byte()
    end,
    
    -- Application Extension
    ["!" .. string.char(0xFF)] = function(stream, out)
        local dataStream = {str=consumeAllBlocks(stream), head=1}

        local name = consume(dataStream, 8)
        seek(dataStream, 3) -- Ignore version
        if name=="NETSCAPE" then
            seek(dataStream, 1) -- Ignore 0x1 byte
            out.loopCount = consumeInt(dataStream, 2)
        end
    end,

    -- Plain Text Extension
    ["!" .. string.char(0x01)] = seekAllBlocks,
    -- Comment Extension
    ["!" .. string.char(0xFE)] = seekAllBlocks
}

-- Loads gif file. If file couldn't be loaded it returns nil and the error message.
-- maxTimePerYield is the maximum allowed time this program can run for in millis before the next yield
-- yieldCallback is the function that can be called after yielding
function gif.load(filename, maxTimePerYield, yieldCallback)
    local contents
    
    if filename:sub(1,8) == "https://" then
        local request,err = http.get(filename)
        if request==nil then
            return request, err
        end
        contents = request.readAll()
        request.close()
    else
        local file, err = fs.open(filename, "r")
        if file==nil then
            return file, err
        end
        contents = file.readAll()
        file.close()
    end

    local out = {}

    local stream = {
        str = contents,
        head = 1
    }

    -- Header Block
    if consume(stream, 3) == "GIF" then
        out.ver = consume(stream, 3)

        -- Contains all image descriptors & their data
        out.dataimages = {}

        -- Logical Screen Descriptor
        out.canvasWidth = consumeInt(stream, 2)
        out.canvasHeight = consumeInt(stream, 2)

        local packedField = consume(stream, 1):byte()

        local globalTableFlag = bit32.extract(packedField, 7, 1)==1
        local colorResolution = bit32.extract(packedField, 4, 3) + 1
        local globalTableSize = 2 ^ (bit32.extract(packedField, 0, 3) + 1)

        out.backgroundColorIndex = consume(stream, 1):byte()

        seek(stream, 1) -- Ignore pixel ratio byte

        -- Global Color Table
        if globalTableFlag then
            out.globalColorTable = consumeColorTable(stream, globalTableSize)
        end

        local startTime = os.epoch("utc")
        while 1 do
            -- TODO: Insert "call func from segments list" stuff here
            local sentinel = consume(stream, 1)

            if sentinel==";" then
                break
            end

            if segments[sentinel] then
                segments[sentinel](stream, out)
            else
                local newSentinel = sentinel .. consume(stream, 1)
                if not segments[newSentinel] then 
                    if sentinel=="!" then -- Skip unknown extension
                        seekAllBlocks(stream)
                    else
                        local hexcode = string.format("%02X %02X", string.byte(sentinel), string.byte(newSentinel:sub(2,2)))
                        return nil, "Invalid segment: " .. hexcode .. " at " .. stream.head
                    end
                end
                segments[newSentinel](stream, out)
            end

            if maxTimePerYield~=nil then
                if os.epoch("utc")-startTime>maxTimePerYield then
                    sleep()
                    if yieldCallback then
                        yieldCallback()
                    end
                end
            end
        end
    else
        return nil, "Invalid GIF header"
    end

    return out
end

-- NOTE: Testing
--local img, err = gif.load("output.gif")
--print(img, err)

return gif