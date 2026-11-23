-- Tiny i18n helper. Reads Accept-Language, picks the first supported locale,
-- and provides t(key) lookups. Add new locales by extending the `locales`
-- table below; missing keys fall back to English.
local ngx = ngx
local _M = {}

local locales = {
    en = {
        upload_title   = "Image Hosting",
        drop_hint      = "Drag & drop an image here, or click to choose",
        api_key        = "API Key",
        upload_btn     = "Upload",
        uploading      = "Uploading...",
        url_label      = "URL",
        markdown_label = "Markdown",
        html_label     = "HTML",
        back_to_upload = "← Back to upload",
        delete         = "Delete",
        confirm_delete = "Delete this image?",
        total_images   = "Images",
        total_size     = "Original size",
        libvips        = "libvips",
    },
    zh = {
        upload_title   = "图床",
        drop_hint      = "拖拽图片到这里，或点击选择文件",
        api_key        = "API Key",
        upload_btn     = "上传",
        uploading      = "上传中...",
        url_label      = "URL",
        markdown_label = "Markdown",
        html_label     = "HTML",
        back_to_upload = "← 返回上传",
        delete         = "删除",
        confirm_delete = "确认删除这张图片？",
        total_images   = "图片总数",
        total_size     = "原始体积",
        libvips        = "libvips",
    },
}

function _M.supported()
    local t = {}
    for k in pairs(locales) do t[#t+1] = k end
    return t
end

function _M.pick(accept)
    accept = accept or ""
    for lang in accept:gmatch("[%w_%-]+") do
        local short = lang:lower():sub(1, 2)
        if locales[short] then return short end
    end
    return "en"
end

function _M.translate(locale, key)
    local l = locales[locale] or locales.en
    return l[key] or locales.en[key] or key
end

-- Return a translate function bound to the request's Accept-Language.
function _M.bind(accept)
    local loc = _M.pick(accept)
    return setmetatable({}, {
        __index = function(_, key)
            return _M.translate(loc, key)
        end,
    }), loc
end

return _M
