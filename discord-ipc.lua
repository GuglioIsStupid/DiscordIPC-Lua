-- Discord IPC lua -- A discord rich presence library for IPC
-- This library is based off of https://github.com/vionya/discord-rich-presence
-- assert jit and ffi

local ffi, jit, e
e, ffi = pcall(require, "ffi")
if not e then
    error("Failed to load FFI library")
end
e, jit = pcall(require, "jit")
if not e then
    error("Failed to load JIT library")
end

ffi.cdef [[
typedef unsigned int size_t;
typedef unsigned short sa_family_t;
typedef unsigned int socklen_t;
typedef int ssize_t;

struct sockaddr {
    sa_family_t sa_family;
    char sa_data[14];
};

struct sockaddr_un {
    sa_family_t sun_family;
    char sun_path[104];
};

int socket(int domain, int type, int protocol);
int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
ssize_t send(int sockfd, const void *buf, size_t len, int flags);
ssize_t recv(int sockfd, void *buf, size_t len, int flags);
int close(int fd);
]]

-- HELPER FUNCTIONS
local curRanSeed = os.time()
local function random(min, max)
    max = max or (2^32)
    min = min or 0
    curRanSeed = (1103515245 * curRanSeed + 12345) % (2^32)
    return min + curRanSeed % (max - min)
end

local function getUUID()
    curRanSeed = os.time()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    local result = string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and random(0, 15) or random(8, 11)
        return string.format("%x", v)
    end)

    return result
end

local function stringify(data)
    local result = {}

    for k, v in pairs(data) do
        local formatted = type(v) == "table" and stringify(v) or tostring(v)

        if type(v) == "string" then
            formatted = '"'..formatted..'"'
        end

        if type(k) == "number" then
            table.insert(result, formatted)
        else
            table.insert(result, string.format("\"%s\":%s", k, formatted))
        end
    end

    if #data > 0 then
        return "["..table.concat(result, ",").."]"
    else
        return "{"..table.concat(result, ",").."}"
    end
end


local function getPID()
    if jit.os == "Windows" then
        ffi.cdef[[
            unsigned long GetCurrentProcessId(void);
        ]]

        return ffi.C.GetCurrentProcessId()
    else
        ffi.cdef[[
            int getpid(void);
        ]]

        return ffi.C.getpid()
    end
end

local function intToBytes(n)
    local hex = string.format("%04x", n)
    local result = {}

    table.insert(result, tonumber(hex:sub(3, 4), 16))
    table.insert(result, tonumber(hex:sub(1, 2), 16))

    for _ = 1, 4 - #result do
        table.insert(result, 0)
    end

    return result
end

local function strToBytes(str)
    local result = {}

    for i = 1, #str do
        table.insert(result, str:byte(i))
    end

    return result
end

local function bytesToInt(bytes)
    local result = 0

    for i, v in ipairs(bytes) do
        result = result + v * (0x100 ^ (i - 1))
    end

    return math.floor(result)
end

local function bytesToStr(bytes)
    local result = ""

    for _, v in ipairs(bytes) do
        local byte = v < 0 and (0xFF + v + 1) or v
        result = result..string.char(byte)
    end

    return result
end

local function pack(opcode, length)
    return bytesToStr(intToBytes(opcode)) .. bytesToStr(intToBytes(length))
end

local function _unpack(str)
    return bytesToInt(strToBytes(str:sub(1, 4))), bytesToInt(strToBytes(str:sub(5, 8)))
end

local discordIPC = {}
function discordIPC:initID(id)
    self.id = id
    self.activity = {}
    self.connected = false
    self.OPCODES = {
        HANDSHAKE = 0,
        FRAME = 1,
        CLOSE = 2,
        PING = 3,
        PONG = 4
    }
    self.PIPE_ENVS = {
        "XDG_RUNTIME_DIR",
        "TMPDIR",
        "TMP",
        "TEMP"
    }
    self.PIPE_PATHS = {
        "",
        "app/com.discordapp.Discord/",
        "snap.discord-canary/",
        "snap.discord/"
    }
end

function discordIPC:connect()
    if not self.id then error("Attempted to connect to Discord IPC without an ID") end

    -- windows machines and unix machines have different ways of connecting to the IPC
    if jit.os == "Windows" then
        for i = 0, 9 do
            local file = io.open("\\\\.\\pipe\\discord-ipc-"..i, "r+")

            if file then
                print("Connected to DiscordIPC Pipe #"..i)
                self.socket = file
            end
        end
    else
        local socket = ffi.C.socket(1, 1, 0)
        if socket < 0 then
            print("Failed to create Discord IPC socket")
            return false
        end

        local env = nil
        for _, v in ipairs(self.PIPE_ENVS) do
            env = os.getenv(v)
            if env then
                if env:sub(-1) == "/" then
                    env = env:sub(1, -2)
                end

                break
            end
        end

        if not env then
            env = "/tmp"
        end

        for i = 0, 9 do
            for _, v in ipairs(self.PIPE_PATHS) do
                local address = ffi.new("struct sockaddr_un")
                address.sun_family = 1
                ffi.copy(address.sun_path, env.."/discord-ipc-"..i)
                local connected = ffi.C.connect(socket, ffi.cast("struct sockaddr*", address), ffi.sizeof(address))

                if connected == 0 then
                    print("Connected to DiscordIPC Pipe #"..i)
                    self.socket = socket
                    self.connected = true
                    break
                end
            end
        end
    end

    if self.socket then
        self.connected = true
        local result = self:sendHandshake()
        print("Successfully connected to Discord IPC")

        return result == self.OPCODES.FRAME
    end
end

function discordIPC:reconnect()
    self:close()
    self:connect()
end

function discordIPC:close()
    if not self.socket then return end

    self:send("{}", self.OPCODES.CLOSE)
    if jit.os == "Windows" then
        self.socket:close()
    else
        ffi.C.close(self.socket)
    end

    self.socket = nil
    self.connected = false

    print("Successfully disconnected Discord IPC")
end

function discordIPC:write(msg)
    if not self.socket then return end

    if jit.os == "Windows" then
        self.socket:seek("end")
        local _, err = self.socket:write(msg)
        self.socket:flush()

        if err then
            print("Failed to write to Discord IPC with error "..err)
        end
    else
        local sent = ffi.C.send(self.socket, msg, #msg, 0)

        if sent < 0 then
            print("Failed to write to Discord IPC")
        end
    end
end

function discordIPC:send(data, opcode)
    self:write(pack(opcode, #data) .. data)

    return self:receive()
end

function discordIPC:sendHandshake()
    print("Awaiting Discord IPC handshake...", '{"v": 1, "client_id": "'..self.id..'"}')
    return self:send('{"v": 1, "client_id": "'..self.id..'"}', self.OPCODES.HANDSHAKE)
end

function discordIPC:sendActivity()
    local data = {
        cmd = "SET_ACTIVITY",
        args = {
            pid = getPID() or 9999,
            activity = self.activity
        },
        nonce = getUUID()
    }

    local o = self:send(stringify(data), self.OPCODES.FRAME)
    print("Sent activity to Discord IPC", stringify(data), o)
    
    return o
end

function discordIPC:clearActivity()
    local activity = {
        cmd = "SET_ACTIVITY",
        args = {
            pid = getPID() or 9999,
            activity = {}
        },
        nonce = getUUID()
    }

    self:send(stringify(activity), self.OPCODES.FRAME)
end

function discordIPC:receive()
    local opcode, length, data = nil, nil, nil

    if jit.os == "Windows" then
        opcode, length = _unpack(self:read(8))
        data = self:read(length)
    else
        local hbuffer = ffi.new("char[8]")
        local hbytes = ffi.C.recv(self.socket, hbuffer, 8, 0)
        opcode, length = _unpack(ffi.string(hbuffer, hbytes))
        
        local dbuffer = ffi.new("char[" .. length .. "]")
        local dbytes = ffi.C.recv(self.socket, dbuffer, length, 0)
        data = ffi.string(dbuffer, dbytes)
    end

    return opcode, data
end

function discordIPC:read(buf)
    if not self.socket then return end

    return self.socket:read(buf)
end

return discordIPC