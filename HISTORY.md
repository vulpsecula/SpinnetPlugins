# Source history

Split from vulpsecula/Spinnet at `91ff874f5494f4e67548626b93e81f24e9dfb4cd`.
Git fast-export/import selected `Plugins/` and `Tests/BundledPluginTests/`;
commits retain authors, dates, messages and parent relationships among relevant
commits. Hashes change because unrelated Host files and commits are excluded.
The original history remains available in the Host repository.

The sole original author approved MIT relicensing in ADR 0014 and issue #66.
The MIT licence applies to the first-party packages and tests in this repository,
including their imported history. No third-party notice was removed or replaced:
the source packages contain only JSON and first-party JavaScript, with no
separately licensed data or assets. Future additions must retain each material's
exact upstream notice alongside it; the repository's MIT licence cannot replace it.

| Original Host commit | Split commit | Subject |
| --- | --- | --- |
| `d19a543864272d67c6a9b971f2e84b956c98ac75` | `65d1cdaa67396569a7c8024a3935de1e1e10d7a3` | Add declarative External App connection prerequisites |
| `5e0a06a406da7ac5eccf538f2a4b67a7020cb0eb` | `a332f41ec6132e8eae8c061bc13d2062aa15a462` | Make the Clipboard History window the only Host Surface |
| `e480d13b3e7dd41ab84f59334e5ff66f245e24a5` | `92992affad1e796e02e12e172c823baee2342236` | Tint Smart Jump's field and show its status inside it |
| `6efd28c8db81c867700878b7f7c808b05a78331e` | `917e921576409368611365d8437eaebcc3052401` | Move Smart Jump's recognition into its Plugin |
| `3a5552ca4324517e30598485ab37554ec682ef88` | `53c346d0736dde3b2d7d2dc8318326f111740790` | Move Translator onto Plugin Views |
| `5ced9bb1d353e6bc46bc60a98fbed71b7f2729d3` | `cd64441621bdc41c96f50954f6313f3fb84f7833` | Migrate text-stored lists once, and move Actions onto Deep Link Templates on install |
| `c38eaa7a49a6928ce6961066678dadaaeb17a65e` | `09f5a4634fd60f1dea94a2956dc71b8a177a5456` | Reach Bob through a Reviewed App Interface and Shottr through Deep Link Templates |
| `f9b6b2f00c7716ed8918f85cd8d9e3305f0c4b30` | `e49b94f47e984dab140cf7e0cf00cb051eb4c9b9` | Replace the search_engines field with a generic list field |
| `6f49f730ccf3e7a24082e745f6ff82bad911791a` | `606cffb8a0ada1733230be70caaa7c73c212eb0a` | Declare Plugin data migrations in the manifest |
| `62c7b5acffe8486edb6d9e39ee4331e7753ba157` | `68974aafede3a131bcd8378c7cc9b023d273e2f1` | Make the Host's own Presets ordinary Plugins |
| `84f24708694340ea8d63b076eed8d2bf88d6674e` | `f1b02390bf70a0eb62d942a6c87f1df6053b8d0a` | Give a Bundled Plugin no privilege an installed one lacks |
| `ce7f2189b96549a7d805637e411605814e9a060d` | `14d4900a8682e2a0a10d77fe965dde575de29e11` | Drop the single-header credential key and pin the Credential Use budgets |
| `45087b3ff6eb5559a498f38293be6fc537e2db78` | `1fd5c1b255427edaee526b204ffd36b14d133cb5` | Apply credentials through Credential Uses |
| `6785fd2151f8ba0ede97dfef33b7e71519c5ffb5` | `9b00df5668713ac429d4c6e5b1081334bd927cf0` | Add a Plugin test kit and run the Bundled Plugins' tests on it |
| `c0e27220c52e4c3a7a10fbe742a286d60f72e869` | `d01c33e5cb3c165258b443fc14d8a4ae1ab69a0b` | Start PluginAPI/ with the manifest schema and Plugin API Level |
| `0d132d05a357f37bb456b7adb0418d5ae795e6e6` | `58ddb669af38dae15ec0772c2fab47ec1a0eb12c` | Share one selected-text reader and use it for Bob |
| `f39ac0d2a04b4e0b7eae21453c86887d60fbf075` | `250d70e2ce853c16a15dd163c6a8e8350516ad55` | Keep Shottr capture behavior in Shottr |
| `97a783142a3ce6a5699504e2f6935e296f8b02cf` | `63b88d8ea12afbf3e29e64626b1baf69f4e9def8` | Add Shottr screenshot commands (#32) |
| `ad5f8dbc49c2075707fa7d987932a8ef97522d96` | `922342e7201038b3967fbcefbcabc33352f2741c` | Add standalone Bob translation plugin |
| `668d5d71ab7da50c43cf73bee305a1299cf4ad29` | `50b2cc42a3c6f6386cd8999d0f9b90a5cfc9a1ea` | Group Plugin Settings, and quieten the translation popup |
| `de7884caab186ccfe46e50e11cc36d1b4bee3c48` | `a2d522bfc08827c14124cd04b09aba63001dbdc9` | Pin a popup, keep its answers, and let Google's address move |
| `1eac3788f138e79f7d8b9335b72fb1ebcf4f2ed0` | `d57db338bb601be8359b8e8b6745962359c45b22` | Change the languages in the translation popup itself |
| `e2ca60c9cd2b905202818c316c86d5d18507028c` | `0f919e02b2ddd9fa0ff67adeca482082cf957066` | Translate in both directions, through Google without a key |
| `cd2b258c96c760b3c3b97976e8aa3dacc442a90e` | `2164823c467fd64650d9a473a445606f1b2dc63b` | Handle unavailable Smart Jump selections |
| `aed72338b70e7e0ec0e9fbbd35cb18908c1f823a` | `d6d4e96c74cc582567f92d83dabd54cbcf44b68e` | Make Smart Jump output permissions optional |
| `17dbed75f29c45b9c0ce2f2fc8308517da44d06e` | `82918c25c6eab6c7ce3e7833a244ceef790906c5` | Make Smart Jump clipboard fallback optional (#46) |
| `9340f5481af2cd1604a27685541c07128c67ab2e` | `460ec6b384973836faf829b46b11bb005e6e09c4` | Implement Smart Jump selected-text fallback (#46) |
| `910fa84bd2bb07b79d631ee9cac2b4caa6d0587b` | `06b0ef040209a1ba5748d89c6fe388bc72d70460` | Polish Smart Jump status and search settings (#46) |
| `2751eb7078d16764b3ca94fa3430e20fad72ac32` | `0055ad5fb2f9a2e5fecb1a61d22db247342a3447` | Recognise selected and typed text with Smart Jump (#46) |
| `c5fb8456a21ad8446dc114068e5edf69cd5676d1` | `780b1dd3c6eb73a13cc545877115ea1e51299b29` | Rework Translator around a shared multi-source popup (#44) |
| `3c7d88b2323f3c4ecb589cd2c35db518f144a4a1` | `5ece7299a98a78c60708291ac0fb15581f7c27a1` | Let Plugins declare Plugin Settings, filled in from the Library |
| `b305253aa626e731642d35c1f56e727afec521fa` | `c4420c847a26d445343f38d64bde6eb7aaa92ae2` | Make screenshots a Host feature other Plugins can reuse (#45) |
| `cc9ce1fedc49f2909cdf2784d855477932173d93` | `c48db913c02ed6966422704d7a2838e203f9a467` | Fix the consent gap and folder check found reviewing #28, #29, #31 |
| `878b5e652dbd14be39b169f43d66d84ab3a86d2e` | `f91352e3c2b368fb25c4ce37ac498def64774936` | Translate selected text through a Bundled Translator Plugin (#29) |
| `6223733ddec5f9ea00649d1ad3b632094f5679f1` | `ed6f83ac3f73826303d663d3ec5072c83c30ba1c` | Capture screenshots natively (#31) |
| `a09857d2b86ee084ca5839cf62585cf15e46f8d4` | `9604098b22385274f2e3eb498255425e5c7bc60a` | Open selected URLs with Smart Jump (#28) |
| `79edb82169f182c2ff9b4d2e5695000d1fa0ea88` | `44fe330bfedc043bcf1c26c5857bc17712ffa6ce` | Let a Command describe what it does |
| `c7936653a503e391f1f203f0667e90763e8c718c` | `26542dca441f1bf57037bed5c0fccf260d38964b` | Resize or move the focused window to exact values (#38) |
| `c92986b6ed19c6013e033ea611de89510b853b70` | `1e4c678386d22fa6d164e16862be308a4762c458` | Restore the focused window to its previous frame (#36) |
| `af39d9ed5e440d3d0191e94671705fb8a539e211` | `6d496f67678609e53b5155d79881782d7e7c978e` | Cycle half-screen layouts on repeated runs (#34) |
| `4f41edc8711a2a87c4eae1ec0e48f3836d9f883e` | `e8e68f505e352e27cb782b10633018e1cd7e90d2` | Move the focused window between displays (#35) |
| `688b13dc23f8898500968d222a0b4c57d47662db` | `0efd77fbcb47a895d8c728fc5b75260c29853bba` | Toggle full screen for the focused window (#37) |
| `7e1bd1b18e4d041af32899e08fc1b06aa53155d9` | `9f9aa328063422436f992eaec092b9bdea990d0d` | Offer the full Window Position layout catalogue (#33) |
| `332516124dc300637e673bb808850e612259e97f` | `842df14f4ccda72e7f081eb7ab6f588f808373c4` | Position the focused window through a Window Position Bundled Plugin (#27) |
| `8c06dc99ca3e1d6f0451a2328a5d1f5398acc9f2` | `53d128911a6d2b2f9624c203e4becbcad4dcb117` | Give presenting the Clipboard History window its own Host Service |
| `591bbb10537e38626851d454d0cf6ae23c565f8f` | `160c0d4fbb39a5903332986c87a4ffa529d83f18` | Author Bundled Plugins under Plugins/ rather than inside the SwiftPM resources |
| `c25ead41a471e8dee28230127617c7eedf78b131` | `f0527d9d0e3121ed51e4e5beace9da1c6144f5a7` | Remove the Spinnet Fixture Plugin and open an empty Menu on first launch |
| `46585fa5a1cd02a9587a9876c4ea0287bbd31bd1` | `bd7f1316ce6b7491640d7be7deb813adbfb45ecb` | Implement common fixture Host Commands (#17) |
| `cbc0fd4d4d142edeb34a4fda7b9e778dce348591` | `1ac37dd1107eb9c0b6beebeb88e59b2970fa1396` | feat: refine slot action configuration UX |
| `4e1105a24a5528fdb0c2088f6c7739c61c446b30` | `9d662f76b216859d0f892871f97fcaf1f87f0869` | feat: add capability-checked host services (#8) |
| `599e93ce03e798810af43f3b953c87d55998fde7` | `f0bd96fdcd61e95d6790725e0311e8dec0863840` | feat: run fixture JavaScript in per-Plugin helper (#7) |
| `43a5ef6f0750193ba078abe7819d6fd5b11fd604` | `56b281cbe7e80f9f880d77c84fa07e5ea061d0f1` | feat: implement frontier ticket 12 walking skeleton |

## Keep Awake onboarding (#95)

`Plugins/KeepAwake.spinnetplugin` preserves the independently accepted Keep Awake
1.0.3 package (`com.spinnet.coffee`), stable Plugin API Level 2, from the external
Coffee proof's `4a7ab74` source (`18f26d7` records acceptance). Its MIT licence
and Dzx copyright notice are copied unchanged. It contains no third-party data
or assets. The accepted public-helper workflow tests move with the package.
Original helper-budget measurements remain evidence of their original revision;
onboarding does not claim a new physical sleep, lid, lock or VoiceOver check.
