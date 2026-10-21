# تجهيز جهازك

الخطوات هذي تسويها مرة وحدة على جهازك (Windows).

## 1. الأدوات

1. ثبت [Roblox Studio](https://create.roblox.com/) و [Git](https://git-scm.com/download/win).
2. ثبت Rokit من PowerShell:

   ```powershell
   Invoke-RestMethod https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.ps1 | Invoke-Expression
   ```

3. انسخ المشروع داخل مجلدك، وثبت الأدوات المثبتة في `rokit.toml`:

   ```powershell
   cd "D:\My Tools\Roblox Strategy Game PLAN"
   git clone https://github.com/TevadYt/roblox-strategy
   cd roblox-strategy
   rokit install
   ```

## 2. ربط الكود مع Studio (Rojo)

1. ثبت إضافة Rojo داخل Studio: `rojo plugin install`.
2. شغل السيرفر من مجلد المشروع: `rojo serve`.
3. في Studio افتح Place جديد، اضغط على إضافة Rojo ثم **Connect**.

أي تعديل في `src` يظهر في Studio مباشرة. لتحديث الكود من GitHub: `git pull`.

## 3. ربط Claude مع Studio (Roblox Studio MCP)

1. نزل آخر إصدار من [Roblox/studio-rust-mcp-server](https://github.com/Roblox/studio-rust-mcp-server/releases) وشغل المثبت. يثبت إضافة MCP في Studio ويربطها مع Claude.
2. إذا تستخدم Claude Code، تأكد إنه ظاهر في `claude mcp list`. إذا ما ظهر، اتبع قسم Claude Code في صفحة المستودع.
3. افتح Studio وخل إضافة MCP شغالة وقت ما تبيني أشتغل على الماب.

## 4. التحكم عن بعد

ثبت [Claude Code](https://claude.com/claude-code) على جهازك. لما أحتاج أشغل شي على جهازك (Rojo أو Studio MCP) يجيك طلب موافقة في المحادثة.
