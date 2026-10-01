import Foundation

@main
enum DiscordParseTests {
    static func main() {
        precondition(DiscordParse.badge(#""StatusLabel"={ "label"="21" }"#) == (21, false), "count")
        precondition(DiscordParse.badge(#""StatusLabel"={ "label"="•" }"#) == (0, true), "dot")
        precondition(DiscordParse.badge(#""StatusLabel"={ "label"="" }"#) == (0, false), "empty label")
        precondition(DiscordParse.badge("") == (0, false), "no badge")
        precondition(DiscordParse.badge(#""StatusLabel"=[ NULL ]"#) == (0, false), "null")

        precondition(DiscordParse.isWebhook("https://discord.com/api/webhooks/123/abc"), "discord.com")
        precondition(DiscordParse.isWebhook("https://canary.discord.com/api/webhooks/123/abc"), "canary")
        precondition(!DiscordParse.isWebhook("http://discord.com/api/webhooks/123/abc"), "plain http")
        precondition(!DiscordParse.isWebhook("https://discord.com.evil.io/api/webhooks/1/a"), "look-alike host")
        precondition(!DiscordParse.isWebhook("https://evil.io/discord.com/api/webhooks/1/a"), "host in path")
        precondition(!DiscordParse.isWebhook("https://discord.com/channels/1/2"), "not a webhook path")
        precondition(DiscordParse.reaction("ya salió el deploy 🎉") == .confetti, "confetti")
        precondition(DiscordParse.reaction("te quiero ❤️") == .hearts, "hearts")
        precondition(DiscordParse.reaction("JAJAJA no puede ser") == .laugh, "laugh, any case")
        precondition(DiscordParse.reaction("😂🎉") == .laugh, "first emoji wins")
        precondition(DiscordParse.reaction("esto está 🔥") == .fire, "fire")
        precondition(DiscordParse.reaction("¿vienes a la llamada?") == .question, "question")
        precondition(DiscordParse.reaction("ok, nos vemos") == nil, "nothing")
        print("Discord parse tests passed")
    }
}
