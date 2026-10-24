# Bedrock Addons

An iOS app for LiveContainer that installs Minecraft Bedrock addons in bulk. The interface is in English and Russian (follows the device language).

1. Install `BedrockAddons.ipa` from the [latest release](../../releases/latest) into the same LiveContainer that runs Minecraft.
2. Tap **Find automatically** to locate Minecraft's `games/com.mojang` folder, or pick it by hand:
   Files → LiveContainer → Data → Application → Minecraft's folder → Documents → games → com.mojang.
   Any folder above `com.mojang` works too, the app finds it inside.
3. Tap **Add files…** and select any number of `.mcpack`, `.mcaddon`, `.mcworld`, `.mctemplate` or `.zip` files.
4. Tap **Install**. Packs go to `resource_packs`, `behavior_packs`, `skin_packs` and `world_templates`, worlds go to `minecraftWorlds`.
   A pack with the same UUID as an installed one replaces it.

Optional steps after installing:
- enable resource packs globally (`minecraftpe/global_resource_packs.json`);
- attach resource and behavior packs to selected worlds (`world_resource_packs.json`, `world_behavior_packs.json`).
  Script packs may also need experimental features turned on in the world settings.

## Building

GitHub Actions (`.github/workflows/build.yml`) generates the Xcode project with XcodeGen, builds an unsigned IPA
and publishes it as the `latest` release. Locally:

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project BedrockAddons.xcodeproj -scheme BedrockAddons -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
