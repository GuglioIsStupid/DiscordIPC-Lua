discordIPC = require("discord-ipc")

discordIPC:initID("746227477801861142")
discordIPC:connect()

discordIPC.activity = {
    details = "WOW!",
    timestamps = {
        start = os.time() * 1000
    },
    assets = {
        large_image = "dj-pp-_-i-feel-the-music"
    }
}

discordIPC:sendActivity()

function love.quit()
    discordIPC:close()
end