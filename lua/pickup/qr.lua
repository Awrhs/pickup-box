-- QR codes rendered server-side as SVG, via libqrencode over LuaJIT FFI.
-- The page needs no JavaScript to show the code, and the SVG scales cleanly.
local ffi = require "ffi"

local _M = {}

ffi.cdef[[
typedef struct {
    int version;
    int width;
    unsigned char *data;
} QRcode;
QRcode *QRcode_encodeString(const char *string, int version, int level,
                            int hint, int casesensitive);
void QRcode_free(QRcode *qrcode);
]]

local QR_ECLEVEL_M = 1
local QR_MODE_8 = 2

local lib
for _, name in ipairs({ "qrencode", "libqrencode.so.4", "libqrencode.so" }) do
    local ok, l = pcall(ffi.load, name)
    if ok then lib = l break end
end

function _M.available()
    return lib ~= nil
end

-- Encode text into a matrix: returns width, rows (array of strings of
-- "1"/"0") or nil, err.
function _M.matrix(text)
    if not lib then return nil, "libqrencode not available" end
    local qr = lib.QRcode_encodeString(text, 0, QR_ECLEVEL_M, QR_MODE_8, 1)
    if qr == nil then return nil, "encode failed" end
    local w = qr.width
    local rows = {}
    for y = 0, w - 1 do
        local row = {}
        for x = 0, w - 1 do
            row[x + 1] = (qr.data[y * w + x] % 2 == 1) and "1" or "0"
        end
        rows[y + 1] = table.concat(row)
    end
    lib.QRcode_free(qr)
    return w, rows
end

-- SVG with a 4-module quiet zone; one path, horizontal runs merged.
function _M.svg(text)
    local w, rows = _M.matrix(text)
    if not w then return nil, rows end
    local q = 4
    local size = w + 2 * q
    local d = {}
    for y, row in ipairs(rows) do
        local x = 1
        while x <= w do
            if row:sub(x, x) == "1" then
                local run = x
                while run + 1 <= w and row:sub(run + 1, run + 1) == "1" do run = run + 1 end
                d[#d + 1] = ("M%d %dh%dv1h-%dz"):format(x - 1 + q, y - 1 + q, run - x + 1, run - x + 1)
                x = run + 1
            else
                x = x + 1
            end
        end
    end
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" '
        .. 'shape-rendering="crispEdges"><rect width="100%%" height="100%%" fill="#fff"/>'
        .. '<path fill="#000" d="%s"/></svg>'):format(size, size, table.concat(d))
end

return _M
