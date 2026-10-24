# Аддоны Bedrock

iOS-приложение для LiveContainer: ставит аддоны в Minecraft Bedrock сразу пачкой.

1. Установи `BedrockAddons.ipa` из [последнего релиза](../../releases/latest) в тот же LiveContainer, где стоит Minecraft.
2. «Найти автоматически» находит `games/com.mojang` Minecraft. Или выбери папку вручную:
   Файлы → LiveContainer → Data → Application → папка Minecraft → Documents → games → com.mojang.
3. «Добавить файлы…» — сколько угодно `.mcpack`, `.mcaddon`, `.mcworld`, `.mctemplate`, `.zip`.
4. «Установить». Паки лягут в `resource_packs`, `behavior_packs`, `skin_packs`, `world_templates`, миры — в `minecraftWorlds`.
   Пак с тем же UUID заменяется новой версией.

После установки по желанию:
- ресурс-паки включаются глобально (`minecraftpe/global_resource_packs.json`);
- ресурс-паки и паки поведения подключаются к выбранным мирам (`world_resource_packs.json`, `world_behavior_packs.json`).

Сборка: GitHub Actions (`.github/workflows/build.yml`) собирает неподписанную IPA через XcodeGen и выкладывает её в релиз `latest`.
