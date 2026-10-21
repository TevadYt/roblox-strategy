# HANDOFF: لعبة استراتيجية بأسلوب Risk على Roblox

> ملف تسليم لأي AI agent يكمل الشغل. اقرأه كامل قبل ما تلمس أي شي.
> آخر تحديث: 2026-10-21. حالة الشغل: **متوقف بطلب صاحب المشروع** لين يقرر الخطوة الجاية. لا تبدأ شي جديد قبل ما تسأله.

---

## 1. فكرة اللعبة باختصار

- لعبة strategy على Roblox بأسلوب **Risk: Global Domination**، والسيرفر هو اللي يقرر كل شي (server-authoritative).
- **6 لاعبين** في السيرفر الواحد (كان 16 وتغيّر إلى 6 بقرار صاحب المشروع).
- **70 territory** بالضبط، و**13 إلى 15 continent** (الحالي 14)، وحوالي 25-30 منطقة محايدة ما تنتمي لقارة (الحالي 30).
- شكل اليابسة مستوحى من **الصين القديمة** (الممالك المتحاربة وتوحيد تشين): خليج كبير في الشمال الشرقي (Bohai)، شبه جزيرة على الساحل الشرقي (Shandong)، ساحل جنوبي متعرّج، ونهرين كبار (الأصفر في الشمال بانحناءة للأعلى، واليانغتسي في الجنوب) يمشون من الغرب للشرق.
- الصين للشكل والنهرين **بس**، مو للمناخ. ممنوع تقسيم مناخي (لا غرب ثلجي ولا شمال صحراوي).
- الماب يتعرض بشكلين: **3D** (مجسم "طاولة حرب" diorama) و**2D** (لوحة مرسومة، تتبدل بزر `M`).

---

## 2. القواعد اللي اتفقنا عليها (ممنوع تكسرها)

المواصفات الكاملة كتبها صاحب المشروع وطلب الالتزام فيها **حرفياً**. أهمها:

### الماب
- ممنوع **الثلج والجليد** نهائياً، حتى لو صور المرجع فيها ثلج.
- أنواع التضاريس: mountain, plateau, plains, valley, desert, forest, pond/lake, rivers.
- التضاريس **موزعة عشوائياً ومخلوطة** في كل الجهات، وممنوع تتجمع في كتل كبيرة.
- المنطقة الوحدة فيها نوع واحد أو 2-3 أنواع مخلوطة (سهل فيه جبل، غابة فيها بركة...).
- الغابات والبرك **resources**: غالباً داخل منطقة ثانية، وأحياناً منطقة لحالها.
- التضاريس داخل كل منطقة **صغيرة وعلى قدّها**، وممنوع سلاسل جبال أو غابات تعدّي حدود المنطقة.
- لازم يظل **وسط كل منطقة فاضي** للمباني وعداد الجنود.
- أشكال المناطق طبيعية وغير منتظمة (لا مربعات ولا hexagons ولا خطوط مستقيمة).
- الأحجام متقاربة، بس الجبال والهضاب أصغر، والسهول والصحاري والوديان أكبر. أكبر منطقة = 2 إلى 2.5 ضعف أصغر وحدة.
- كل منطقة لها **جارين على الأقل**، والجيران متطابقين من الطرفين.
- **الأنهار تمشي على حدود المناطق**، مو في وسطها.
- **الحدود**: خط رفيع رمادي شفاف باهت.
- **القارة** = 2 إلى 5 مناطق متجاورة يغلب عليها نفس نوع التضاريس. يحيط فيها **خط ذهبي رفيع على حدودها الخارجية بس**. ممنوع دمج مناطقها في شكل واحد، وممنوع تلوين القارة بلون كامل. كل منطقة داخلها تحتفظ بحدودها الرمادية.
- لما لاعب يسيطر على قارة كاملة، الخط الذهبي يتحول للون اللاعب.
- ممنوع أي نص أو أسماء على الصورة الفنية؛ الأسماء تنحط في واجهة Roblox.

### الكود (من `CLAUDE.md`)
- كل ملف يبدأ بـ `--!strict`، والامتداد `.luau`.
- أرقام اللعبة في `src/shared/GameConfig.luau` بس، مو inline.
- كل نظام server جديد = module في `src/server/Services` فيه `Init`/`Start`، و`Init` ما يسوي yield.
- لا تثق في أي قيمة من الـ client. الـ state لكل لاعب في Player attributes، وإذا يحتاج events فـ RemoteEvent مع validation على السيرفر.
- CI يشغل: `stylua --check src` و`selene src` و`rojo build -o game.rbxl`. خلّه أخضر دايم.

### قواعد التعامل
- **ممنوع تنشر (publish) المكان أو اللعبة على Roblox** بدون موافقة صريحة.
- رفع الـ meshes لحساب صاحب المشروع كـ private assets **انوافق عليه مرة** (للـ board.fbx). أي رفع جديد اسأل عنه.
- ممنوع تحذف ملفات صاحب المشروع.
- الردود معه **بالعربي** (لهجة خليجية بسيطة)، قصيرة وواضحة.
- لا تبني الماب قطعة قطعة بأوامر MCP منفصلة. هذا حرق tokens كثير وصاحب المشروع اعترض عليه. اشتغل بـ **scripts** تبني كل شي مرة وحدة، وتأكد بـ screenshot وحدة.

---

## 3. خط الإنتاج (pipeline) المعتمد

```
map_data.json  ──►  Python (هيكل + تحقق)  ──►  Blender (مجسم 3D)  ──►  FBX  ──►  Studio Import 3D  ──►  BoardMeshes.luau  ──►  MapBuilder
                         │
                         └──►  map_structure.png  ──►  GPT Image (لوحة 2D فنية)  ──►  خلفية الماب 2D
```

1. **المرحلة 1 (Python):** `tools/mapgen/generate_map.py` يولّد الماب من seed (الحالي `67`)، ويطلع `map_data.json` و`map_structure.png/svg` ونسخة مرقّمة، ويتحقق من كل القواعد ويكتب `validation.txt`. `tools/mapgen/export_roblox.py` يحوّل البيانات إلى `src/shared/MapData.luau`.
2. **المرحلة 2 (GPT Image):** صاحب المشروع يعطي `map_structure.png` (بدون أرقام) لـ GPT Image مع البرومبت في `assets/map/art_prompt.md`. **ما رجعت لنا الصورة الفنية للحين.**
3. **المرحلة 3 (Roblox):** الصورة الفنية خلفية للـ 2D، والحدود والقارات وألوان اللاعبين ترتسم من البيانات.
4. **الـ 3D:** `tools/blender/build_board.py` يبني الماب في Blender من `map_data.json` (حوالي 7 ثواني)، ويطلع `board.blend` و`board.fbx`: 156 mesh object بأسماء `Ground_01..70` و`Props_01..70` و`Edge_01..14` (الحواف الذهبية للقارات) و`Rivers` و`LandBase`. بعدها import في Studio، وتسجيل الـ asset ids والـ CFrames في `src/shared/BoardMeshes.luau`.

---

## 4. وش خلص (المستودع `TevadYt/roblox-strategy`)

| PR | الفرع | المحتوى | الحالة |
|---|---|---|---|
| #1 | `rojo-scaffold` | هيكل Rojo (Server/Client/Shared)، Rokit/Wally/Selene/StyLua، CI، `docs/SETUP.md`، نظام موارد بسيط (Gold/Wood/Stone) وResource HUD | **مدموج في `main`** |
| #2 | `risk-map-structure` → `main` | مولّد الماب بـ Python والمرحلة 1 كاملة (70 منطقة، 14 قارة، 30 محايدة، النهرين + 3 روافد، 5 sea routes) | مفتوح |
| #5 | `roblox-map-build` → `risk-map-structure` | بناء الماب 3D في Roblox: أول شي parts، بعدين Blender meshes؛ الكاميرا 3D/2D؛ البيئة | مفتوح |
| #3 | `claude/project-thread-9knup1` | 6 لاعبين (seat + لون لكل لاعب: أحمر، أزرق، أخضر، أصفر، بنفسجي، برتقالي)، توزيع الـ 70 منطقة، الضغط لاختيار منطقة، HUD | مفتوح، مبني فوق #5 |
| #4 | `claude/project-thread-iv99mv` | نظام الأدوار والمعارك (reinforce, attack بالنرد, occupy, fortify)، الإقصاء والفوز، 14 test | مفتوح، مبني فوق #3 |

**ترتيب الدمج إلزامي:** `#2` ← `#5` ← `#3` ← `#4`. كل الـ CI كان أخضر آخر مرة.

> ملاحظة: #3 و#4 قاعدتهم `main` في GitHub مع إنهم stacked، فالـ diff يبين أكبر من الحقيقة لين ينضم اللي قبلهم.

### تفاصيل مهمة في الكود
- **`GameConfig.Map.WorldScale = 0.25`**: `MapBuilder` يبني الماب بالمقاس التصميمي وبعدين `map:ScaleTo(0.25)` حول الأصل. السبب: على جودة الرسم التلقائية، Roblox ما يرسم الأجزاء الأبعد من ~500 stud عن الكاميرا، والكاميرا كانت على 950 (وفي 2D حوالي 4000)، فاللاعب كان يشوف أسماء المناطق بس بدون أرض. المقاس التصميمي حوالي `1419 × 34 × 915` stud، وبعد التصغير حوالي `355 × 8.5 × 229`.
- `StudsPerPixel = 0.5` قيمة تصميمية. **مواقع العالم = موقع التصميم × WorldScale**. attribute `Top` لكل territory بوحدات العالم.
- `Players.CharacterAutoLoads = false` (يتضبط في `MapService:Init`).
- الهيكل في Workspace: `workspace.Map.Territories.Territory_XX` مع attributes `Id` و`Name` و`Continent`، وفولدر `Slab` فيه قطع أرض المنطقة. PR #3 يعتمد على هذا للضغط والتلوين، **لا تغيّره**.
- وضع الـ meshes: الماب = 514 قطعة بس (بدل 31,910 في وضع الـ parts)، ويتبني في 2.6 ثانية بدون أخطاء. يحمّل الـ meshes بـ `InsertService:CreateMeshPartAsync`.
- `BoardMeshes.luau` و`MapData.luau` ملفات generated وموجودة في `.styluaignore`.
- قواعد المعركة (PR #4): التعزيز = عدد أراضيك ÷ 3 (أقل شي 3) + مكافأة القارات. المهاجم حتى 3 نرد والمدافع حتى 2، والتعادل للمدافع. المباراة تبدأ بلاعبين أو أكثر بعد عد تنازلي 15 ثانية. كل الأرقام في `GameConfig.Match`. **ما فيه** كروت Risk ولا blitz للحين.
- لازم صاحب المشروع يضبط Max Players = 6 من Game Settings في Studio.

### القارات الحالية (seed 67)

| # | الاسم | التضاريس | المناطق | المكافأة |
|---|---|---|---|---|
| 1 | هضبة اللوس | plateau | 29, 30, 44, 45 | 5 |
| 2 | سهول هيبي | plains | 51, 52, 53 | 3 |
| 3 | سهول تشي | plains | 37, 38 | 2 |
| 4 | غابات تشو | forest | 20, 33, 47 | 3 |
| 5 | هضبة لونغيو | plateau | 40, 41, 55, 57 | 5 |
| 6 | جبال تشينلينغ | mountain | 7, 8, 23 | 4 |
| 7 | أحراش وو يويه | forest | 1, 2 | 2 |
| 8 | كثبان هيتاو | desert | 12, 13, 26 | 3 |
| 9 | وادي هان | valley | 9, 10, 11 | 3 |
| 10 | هضبة شانغلو | plateau | 62, 63, 64 | 4 |
| 11 | وادي لوه | valley | 4, 5, 19 | 3 |
| 12 | قمم تاي شان | mountain | 65, 68 | 3 |
| 13 | قفار جيوتشيوان | desert | 18, 31, 32 | 3 |
| 14 | مرتفعات تايهانغ | mountain | 16, 17 | 3 |

---

## 5. أماكن الملفات

### في المستودع
- `tools/mapgen/` مولّد الماب (Python) و`tools/blender/` سكربت Blender.
- `assets/map/` البيانات والمخططات والبرومبت و`blender/board.blend` و`blender/board.fbx`.
- `src/server/MapBuilder.luau` و`src/server/Map/` (Environment, Props) و`src/client/MapCamera.luau`.
- فرع `studio-shots` فيه صور Studio في `assets/map/studio/` (`01..04_*.jpg` نسخة الـ parts، و`v3_*.jpg` نسخة الـ meshes).

### على جهاز صاحب المشروع (Windows, `DESKTOP-BNTN7KO`)
المجلد الرئيسي: `D:\My Tools\Roblox Strategy Game PLAN\`
- `repo\` git clone شغّال على فرع `roblox-map-build`. **هذا اللي تشتغل فيه.**
- `roblox-strategy\` نسخة قديمة من أول scaffold، لا تعتمد عليها.
- `map\` المخرجات: `v1\` (المرحلة 1)، `studio\` (صور)، `blender\board.blend`.
- `risk_map_v4.rbxl` آخر place مبني (WorldScale 0.25).
- `.mcp.json` فيه الـ MCP servers (تحت).

### ملفات المشروع المشتركة (Claude project files)
`/mnt/project-files/map/`: `v1/`، `studio/`، `blender/`، `roblox/risk_map.rbxl`، `previews/`.

---

## 6. الأدوات والـ MCPs

- **Rojo 7.4.4** (عبر Rokit)، **Wally**، **Selene**، **StyLua**. النسخ مثبتة في `rokit.toml`.
- **Roblox Studio MCP** الرسمي ([studio-rust-mcp-server](https://github.com/Roblox/studio-rust-mcp-server))، وإعداده في `.mcp.json`:
  ```json
  {
    "mcpServers": {
      "Roblox_Studio": {
        "command": "cmd.exe",
        "args": ["/c", "cd /d %LOCALAPPDATA%\\Roblox && .\\mcp.bat"]
      },
      "blender": { "command": "uvx", "args": ["blender-mcp"] }
    }
  }
  ```
  يعطي أدوات مثل `execute_luau`/`run_code` و`screen_capture`. Studio لازم يكون مفتوح.
- **Blender MCP** ([ahujasid/blender-mcp](https://github.com/ahujasid/blender-mcp)) يحتاج `uv`. في Blender: اضغط `N` ← تبويب **BlenderMCP** ← **Connect** (port `9876`).
- **Claude Remote Control**: صاحب المشروع يشغّل `claude remote-control` **من داخل** `D:\My Tools\Roblox Strategy Game PLAN` (لما انشغّل من `C:\Users\Magic` ما اشتغل Studio). إذا انقطع الاتصال، اطلب منه يعيد تشغيله في نفس المجلد.
- **ForgeGUI** (connector من طرف ثالث، Streamable HTTP، تسجيل دخول بحسابه): مفيد لواجهات GUI وسكربتات Luau، مو للماب. لا يعطيه باسوورد Roblox أبداً.
- **Studio Import 3D** لملف `board.fbx`: Merge Meshes **off**، Anchored **on**، Upload to Roblox **on**، Insert Using Scene Position **on**، Set Pivot to Scene Origin **on**، الوحدة Stud، scale 1. السكربتات ما تقدر تفتح الـ importer، فيحتاج computer use أو صاحب المشروع يضغط بنفسه.

### Skills
- رسمية من Roblox داخل Studio (عبر الـ MCP): `rbx-scene-analysis`، `rbx-perf-profiling`، `rbx-debug`، `rbx-unit-test`، `rbx-docs-search`.
- من المجتمع (اقرأ `SKILL.md` قبل الاستخدام، ولا تشغّل سكربتاتها قبل ما تفحصها): [roblox-brain](https://github.com/TabooHarmony/roblox-brain)، [awesome-gamedev-agent-skills](https://github.com/gamedev-skills/awesome-gamedev-agent-skills).
- **مقترحة للمشروع (ما انكتبت للحين):**
  1. `risk-map-pipeline`: يمشي الماب بالترتيب JSON ← Python ← Blender ← Studio، ويتأكد إن كل territory ماخذ رقمه.
  2. `studio-mcp-workflow`: سكربت واحد بدل مئات الأوامر، وتحقق بـ screenshot وحدة.
  3. `luau-service`: قالب لأي server service جديد على قواعد `CLAUDE.md`.

---

## 7. وين وقفنا بالضبط

1. الماب الـ mesh المصغّر (WorldScale 0.25) **يتبني في Studio بدون أخطاء** (`risk_map_v4.rbxl`).
2. **مشكلة مفتوحة:** البحر (Terrain water) **يغطي السواحل المنخفضة**، وفيه مشاكل voxel بحجم 4 stud. القرار: لا نصلح الـ Terrain sea، نستبدله.
3. صاحب المشروع شاف الشكل "رخيص" (ألوان سادة + low-poly). بدأنا **realism pass** وتوقف قبل ما يتنفذ. الخطة كانت:
   - **البحر:** seabed mesh عليه texture مخبوزة من الضحل للعميق + سطح ماء Part بمادة Glass. هذا يحل مشكلة السواحل.
   - **Blender:** نحت relief حقيقي للأرض (الجبال والهضاب مرتفعة فعلاً، مع منحدرات صخرية)، planar UVs عشان مواد PBR في Roblox (Grass, LeafyGrass, Rock, Sand, Sandstone, Wood) تتكرر صح، وتقسيم الـ props حسب المادة (صنوبر، أوراق، جذوع، صخور، حقول، برك). بعدها FBX جديد ← import ← إعادة توليد `BoardMeshes.luau`.
   - **الإضاءة:** `Lighting.Technology = Future`، Atmosphere، Sky، post-processing (ColorCorrection, Bloom, SunRays, DepthOfField خفيف)، شمس ذهبية، ظلال ناعمة، وتأثير tilt-shift يخلي الطاولة تبان مجسم مصغّر.
   - **الشجر والصخور:** مجسمات بجودة أعلى (من Blender أو Creator Store).
   - Roblox ما يقبل texture أكبر من 1024×1024، فالواقعية تجي من المواد والإضاءة، مو من الدقة.
   - لازم يشتغل كويس على **الجوال**.
4. **قرار معلّق عند صاحب المشروع (بطاقة اختيار ستايل الماب):**
   - مجسم واقعي فاخر (diorama): **الموصى به**، ويشتغل على الجوال.
   - واقعي كامل (فوتوغرافي): أثقل وممكن يعلّق على الجوالات.
   - رسم فني ملوّن: خفيف بس مو واقعي.
5. PRs #2 و#3 و#4 و#5 كلها مفتوحة وتنتظر مراجعته ودمجه.

---

## 8. الخطوات الجاية (بالترتيب المقترح)

> **قبل أي شي:** اسأل صاحب المشروع وش يبي يبدأ فيه، لأنه هو اللي أوقف الشغل.

1. **ادمج PRs بالترتيب** #2 ← #5 ← #3 ← #4 (بعد موافقته)، وتأكد إن CI أخضر بعد كل دمج.
2. **جرّب مباراة كاملة** بـ 6 لاعبين في Studio (Test ← Players). هذي توصية سابقة: لعبة تنلعب قبل التجميل، عشان نعرف وش يحتاج الماب فعلاً.
3. **حل مشكلة البحر** (seabed mesh + Glass water) كجزء من الـ realism pass.
4. **realism pass** على حسب الستايل اللي يختاره (الخطوات في القسم 7).
5. **الماب 2D:** لما ترجع صورة GPT Image، حطها خلفية لعرض 2D وارسم فوقها الحدود وألوان اللاعبين من البيانات.
6. إضافات اللعب: كروت Risk، زر blitz، تحسين الـ HUD (ممكن ForgeGUI يساعد في الواجهات).
7. اكتب الـ 3 Skills المقترحة إذا وافق.

---

## 9. نصايح للـ agent الجاي

- صاحب المشروع يكتب بالعربي ويحب يشوف **صور** للتقدم. أرسل screenshot بعد كل خطوة واضحة.
- لا تقول إن شي "شغّال" قبل ما تتأكد منه فعلاً (صارت مرة وقلنا الجلسة بدأت وطلعت ما بدأت).
- لما تحتاج تبني شي في Studio: اكتب الكود في المستودع، `rojo build`، وشغّل `require(game.ServerScriptService.Server.MapBuilder).build(workspace)` مرة وحدة عن طريق الـ MCP.
- إذا عدّلت أي شي يأثر على المقاسات أو هيكل `workspace.Map`، تأكد إن PR #3 و#4 ما ينكسرون.
- روابط مفيدة: خطة المشروع وبرومبت GPT Image ودليل صناعة الماب موجودة كـ Artifacts في claude.ai عند صاحب المشروع. إذا ما تقدر تفتحها، اطلبها منه.
