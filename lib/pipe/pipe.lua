local strutil = require("acid.strutil")
local tableutil = require("acid.tableutil")
local semaphore = require("ngx.semaphore")
local pipe_filter = require("pipe.filter")

local _M = { _VERSION = '1.0' }
local mt = { __index = _M }

local to_str = strutil.to_str
local SEMAPHORE_TIMEOUT = 300 --seconds

local function wrap_co_func(co, ...)
    local ok, rst, err_code, err_msg = pcall(co.func, ...)

    co.sema_buf_ready:post(1)
    co.sema_buf_filled:post(1)
    co.sema_dead:post(1)

    if ok and err_code == nil then
        co.result = rst
    else
        if not ok then
            err_code, err_msg = 'CoroutineError', rst
        end
        co.err = {err_code = err_code, err_msg = err_msg}
        ngx.log(ngx.ERR, "coroutine exit with error:", to_str(co.err))
    end

    co.is_dead = true
end

local function spawn_coroutines(functions)
    local cos = {}

    for ident, func in ipairs(functions) do
        table.insert(cos, {
            ident     = ident,
            func      = func,

            result    = nil,
            err       = nil,

            is_dead   = false,
            is_eof    = false,

            sema_buf_ready  = semaphore.new(),
            sema_buf_filled = semaphore.new(),
            sema_dead       = semaphore.new(),
        })
    end

    return cos
end

local function start_coroutines(self, ...)
    for _, cos in ipairs({...}) do
        for _, co in ipairs(cos) do
            co.co = ngx.thread.spawn(wrap_co_func, co, self, co.ident)
        end
    end
end

local function kill_coroutines(...)
    for _, cos in ipairs({...}) do
        for _, co in ipairs(cos) do
            ngx.thread.kill(co.co)
            co.is_dead = true
        end
    end
end

local function get_pipe_result(self)
    local rst = {
        read_result = {},
        write_result = {},
    }

    for _, co in ipairs(self.rd_cos) do
        table.insert(rst.read_result, {
            err = co.err,
            result = co.result,
        })
    end

    for _, co in ipairs(self.wrt_cos) do
        table.insert(rst.write_result, {
            err = co.err,
            result = co.result,
        })
    end

    return rst
end

local function set_write_result(self, rst)
    for _, co in ipairs(self.wrt_cos) do
        if type(rst) == 'table' then
            co.result = tableutil.dup(rst, true)
        else
            co.result = rst
        end
    end
end

local function is_all_nil(bufs, n)
    for i = 1, n, 1 do
        if bufs[i] ~= nil then
            return false
        end
    end
    return true
end

local function set_nil(bufs, n)
    for i = 1, n, 1 do
        bufs[i] = nil
    end
end

local function is_read_eof(self)
    for _, co in ipairs(self.rd_cos) do
        if co.is_eof == false then
            return false
        end
    end
    return true
end

local function post_co_sema(cos, sema)
    for i, co in ipairs(cos) do
        co[sema]:post(1)
    end
end

local function wait_co_sema(cos, sema)
    for i, co in ipairs(cos) do
        if not co.is_dead then
            local ok, err = co[sema]:wait(SEMAPHORE_TIMEOUT)
            if err then
                co.err = {
                    err_code = 'SemaphoreError',
                    err_msg  = to_str('wait sempahore ', sema, ' error:', err),
                }
            end
        end
    end
end

function _M.new(_, rds, wrts, filter)
    if #rds == 0 or #wrts == 0 then
        return nil, 'InvalidArgs', 'reader or writer cant be empty'
    end

    local obj = {
        n_rd  = #rds,
        n_wrt = #wrts,

        rbufs = {},
        wbufs = {},

        filter = filter or pipe_filter.copy_filter,
    }

    obj.rd_cos  = spawn_coroutines(rds)
    obj.wrt_cos = spawn_coroutines(wrts)

    return setmetatable(obj, mt)
end

function _M.write_pipe(pobj, ident, buf)
    local rd_co = pobj.rd_cos[ident]

    local ok, err = rd_co.sema_buf_ready:wait(SEMAPHORE_TIMEOUT)
    if err then
        return nil, 'SemaphoreError', 'wait buffer ready sempahore:' .. err
    end

    if buf == '' then
        rd_co.is_eof = true
    end

    pobj.rbufs[ident] = buf

    rd_co.sema_buf_filled:post(1)
end

function _M.read_pipe(pobj, ident)
    local wrt_co = pobj.wrt_cos[ident]

    local ok, err = wrt_co.sema_buf_filled:wait(SEMAPHORE_TIMEOUT)
    if err then
        return nil, 'SemaphoreError', err
    end

    local buf = pobj.wbufs[ident]
    pobj.wbufs[ident] = nil

    wrt_co.sema_buf_ready:post(1)

    return buf
end

function _M.pipe(self, is_running)
    start_coroutines(self, self.rd_cos, self.wrt_cos)

    while not is_read_eof(self) do
        if not is_running() then
            kill_coroutines(self.rd_cos, self.wrt_cos)
            return nil, 'AbortedError', 'aborted by caller'
        end

        set_nil(self.rbufs, self.n_rd)
        post_co_sema(self.rd_cos, 'sema_buf_ready')
        wait_co_sema(self.rd_cos, 'sema_buf_filled')

        local rst, err_code, err_msg = self.filter(self.rbufs, self.n_rd,
            self.wbufs, self.n_wrt, get_pipe_result(self))
        if err_code ~= nil then
            kill_coroutines(self.rd_cos, self.wrt_cos)

            if err_code ~= 'InterruptError' then
                return nil, err_code, err_msg
            end

            set_write_result(self, rst)
            return get_pipe_result(self)
        end

        if is_all_nil(self.wbufs, self.n_wrt) then
            kill_coroutines(self.rd_cos, self.wrt_cos)
            return nil, 'PipeError', 'to write data can not be nil'
        end

        post_co_sema(self.wrt_cos, 'sema_buf_filled')
        wait_co_sema(self.wrt_cos, 'sema_buf_ready')
    end

    wait_co_sema(self.wrt_cos, 'sema_dead')
    kill_coroutines(self.rd_cos, self.wrt_cos)

    return get_pipe_result(self)
end

return _M
