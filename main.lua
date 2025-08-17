discordIPC = require("discord-ipc")

discordIPC:initID("746227477801861142")
discordIPC:connect()

discordIPC.activity = {
    state = "I feel the music",
    details = "WOW!",
    timestamps = {
        start = os.time() * 1000,
        ["end"] = os.time() * 1000 + 3600000
    },
    assets = {
        large_image = "test",
        small_image = "test",
        large_text = "test",
        small_text = "test"
    },
    --[[ 
    party = {
        id = "test",
        size = {
            1,
            2
        }
    }, ]]
    --[[
    secrets = {
    join = "test",
    spectate = "test",
    match = "test"
    },
    ]]
    --[[
    instance = false
    ]]
}

discordIPC:sendActivity()

function love.quit()
    discordIPC:close()
end