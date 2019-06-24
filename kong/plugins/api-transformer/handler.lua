local BasePlugin = require("kong.plugins.base_plugin")
local MyPlugin = BasePlugin:extend()
local _inspect_ = require("inspect")
local _utils = require("kong.plugins.api-transformer.utils")
local _cjson_decode_ = require("cjson").decode
local _cjson_encode_ = require("cjson").encode


local _get_env_ = function()
  return {
    ngx = {
      ctx = ngx.ctx,
      var = ngx.var,
      req = {
        get_headers =  ngx.req.get_headers,
        set_header = ngx.req.set_header,
        get_method = ngx.req.get_method,
        get_body_data = ngx.req.get_body_data,
        set_body_data = ngx.req.set_body_data,
        get_uri_args = ngx.req.get_uri_args,
        set_uri_args = ngx.req.set_uri_args,
      },
      resp = {
        get_headers = ngx.resp.get_headers,
      }
    }
  }
end


function MyPlugin:new()
  MyPlugin.super.new(self, 'api-transformer')
end


function MyPlugin:access(config)
  MyPlugin.super.access(self)

  ngx.req.read_body()

  local _req_body = ngx.req.get_body_data()

  local s, _req_json_body = pcall(function() return _cjson_decode_(_req_body) end)
  if not s then
    _req_json_body = nil
  end

  -- save vars into context for later usage
  ngx.ctx._parsing_error = false
  ngx.ctx.req_uri = ngx.var.uri
  ngx.ctx.req_method = ngx.req.get_method()
  ngx.ctx.req_json_body = _req_json_body

  local p_status, f_status, req_body_or_err  = _utils.run_untrusted_file(config.request_transformer, _get_env_())

  if not p_status then
    ngx.ctx._parsing_error = true
    return kong.response.exit(500, "transformer script parsing failure.")
  end

  if not f_status then
    ngx.ctx._parsing_error = true
    return kong.response.exit(500, req_body_or_err)
  end

  if type(req_body_or_err) ~= "string" then
    ngx.ctx._parsing_error = true
    return kong.response.exit(500, "unknown error")
  end

  if string.len(req_body_or_err) > 0 then
    ngx.req.set_body_data(req_body_or_err)
    ngx.req.set_header(CONTENT_LENGTH, #req_body_or_err)
  end

  ngx.ctx._resp_buffer = ''
end


function MyPlugin:header_filter(config)
  ngx.header["content-length"] = nil -- this needs to be for the content-length to be recalculated

  if ngx.ctx._parsing_error then
    return
  end
  if config.http_200_always then
    ngx.status = 200
  end
end


function MyPlugin:body_filter(config)
  MyPlugin.super.body_filter(self)

  local chunk, eof = ngx.arg[1], ngx.arg[2]

  if not eof then
    if ngx.ctx._resp_buffer and chunk then
      ngx.ctx._resp_buffer = ngx.ctx._resp_buffer .. chunk
    end
    ngx.arg[1] = nil

  else
    -- body is fully read
    local raw_body = ngx.ctx._resp_buffer
    if raw_body == nil then
      return ngx.ERROR
    end

    ngx.ctx.resp_json_body = _cjson_decode_(raw_body)


    local p_status, f_status, resp_body_or_err = _utils.run_untrusted_file(config.response_transformer, _get_env_())

    local resp_body = {
      data = {},
      error = {code = -1, message = ""}
    }

    if (not p_status) or (type(resp_body_or_err) ~= "string") then
      if config.http_200_always then
        resp_body.error.code = 500
        resp_body.error.message = "transformer script parsing failure."
        ngx.arg[1] = _cjson_encode_(resp_body)
      else
        return kong.response.exit(500, "transformer script parsing failure.")
      end
    elseif not f_status then
      if config.http_200_always then
        resp_body.error.code = 500
        resp_body.error.message = resp_body_or_err
        ngx.arg[1] = _cjson_encode_(resp_body)
      else
        return kong.response.exit(500, resp_body_or_err)
      end
    else
      ngx.arg[1] = resp_body_or_err
    end

  end

end

MyPlugin.PRIORITY = 801

return MyPlugin