# הוצאת גרסה, מפתח חתימה ועדכונים

## איך עדכון מגיע למשתמש

1. במסד שאצל המשתמש כתובים `update_manifest_url` ו-`update_public_key` (מ-`library.json`). אוצריא נועצת אותם
   בפעם הראשונה שהיא רואה את המסד.
2. אוצריא מורידה את `https://github.com/Otzaria/zmanenu-library/releases/latest/download/manifest.json` ואת
   `manifest.json.sig` מאותה כתובת, ובודקת את החתימה מול המפתח הנעוץ. GitHub מפנה את `latest/download` לרילייס
   האחרון שאינו טיוטה, והלקוח עוקב אחרי עד 5 הפניות ובודק כל אחת מהן.
3. אם `db_version` במניפסט גדול מהמותקן, מוצע עדכון. הלקוח מעדיף תיקון דלתא מהגרסה המותקנת, ובכל כשל חוזר
   לקובץ המלא. החלקים יושבים בכתובות קבועות של הרילייס: `releases/download/vN/...`.

## כתובות קבועות לכל גרסה

כל רילייס מתויג **בדיוק** `v<db_version>` (למשל `v7`), והמניפסט החתום שלו נשאר לתמיד בכתובת:

```
https://github.com/Otzaria/zmanenu-library/releases/download/v<db_version>/manifest.json
https://github.com/Otzaria/zmanenu-library/releases/download/v<db_version>/manifest.json.sig
```

אוצריא משתמשת בכתובות האלה כדי לזהות עותק שצורף ידנית, מכל גרסה שפורסמה. ה-workflow מוודא אחרי הפרסום ששתי
הכתובות עונות.

**אסור למחוק רילייס, לשנות את התגית שלו או להחליף את הקבצים שבו.** מלבד זיהוי עותקים ידניים, הבנייה הבאה
מורידה מהרילייסים את המסדים הקודמים (מזהי ספרים ודלתות), ומשתמשים בגרסאות ישנות מורידים מהם את חלקי הדלתא.
מומלץ להפעיל ב-Settings ← General את **Release immutability**, אם היא זמינה לריפו.

## קובצי הרילייס

| קובץ | מה |
|---|---|
| `manifest.json`, `manifest.json.sig` | המניפסט והחתימה עליו (ed25519, base64 ושורה חדשה) |
| `otzaria.zmanenu-<N>.db.zst` (או חלקים שלו) | המסד המלא, דחוס ב-zstd |
| `otzaria.zmanenu-<N>.db.from-<M>.patch.zst` | תיקוני דלתא מגרסאות קודמות |
| `zmanenu-offline.tar.zst` (או, מעל 2GB, חלקים ומניפסט) | חבילת האופליין, ראו בהמשך |

### חבילת האופליין — `zmanenu-offline.tar.zst`

ארכיון tar דחוס ב-zstd, שאוצריא יכולה לייבא ולאמת בלי רשת. זה אותו פורמט כמו חבילת הספרייה הרשמית
`otzaria-<version>-library.tar.zst` (`build-and-announce.yml` באפליקציה). בשורש ה-tar יש **בדיוק** שלוש רשומות,
בלי תיקיות:

| שם | תוכן |
|---|---|
| `zmanenu.db` | המסד המלא, לא דחוס בתוך ה-tar. ה-sha256 והגודל שלו שווים ל-`full.sha256` ול-`full.size` שבמניפסט |
| `manifest.json` | זהה בבתים לקובץ שמתפרסם ברילייס |
| `manifest.json.sig` | זהה בבתים לקובץ שמתפרסם ברילייס |

- **דחיסה:** `zstd -19 -T0`, כמו החבילה הרשמית. בלי `--long`, כך שהחלון נשאר בתוך ברירת המחדל של המפענח
  (`windowLogMax` 27), ו-`zstd_stream_extractor.dart` באפליקציה פותח אותה בלי הגדרה נוספת.
- **tar דטרמיניסטי:** רשומות ממוינות לפי שם, mtime קבוע (2020-01-01), בעלים 0, הרשאות 0644, ושמות ב-UTF-8
  (פורמט PAX). אותם קבצים נותנים בדיוק אותה חבילה.
- **אימות בייבוא:** לבדוק את `manifest.json.sig` מול המפתח הנעוץ, לקרוא את `full.sha256` ו-`full.size`, ולוודא
  שהם מתאימים ל-`zmanenu.db`. `library_id` ו-`db_version` במניפסט מזהים את הגרסה.
- הקובץ מחליף את `zmanenu.zip` של הגרסאות הראשונות.
- נבנה ב-[`scripts/offline_bundle.py`](../scripts/offline_bundle.py), שמחלץ אותו שוב בסוף ובודק את הרשומות,
  את ה-sha ואת הזהות בבתים של המניפסט והחתימה.

**שני מצבים אפשריים:**

- **עד 1992294400 בתים** (מתחת למגבלת 2GiB של GitHub): קובץ אחד, `zmanenu-offline.tar.zst`, בלי מניפסט חלקים.
- **מעל הסף:** פיצול במוסכמה של הספרייה הרשמית (`tool/release/split_release_asset.sh` באפליקציה):
  - `zmanenu-offline.tar.zst.part-000`, `part-001` וכן הלאה, כל אחד עד 1992294400 בתים.
  - `zmanenu-offline.tar.zst.manifest.json`, עם `schemaVersion`, `archive`, `size`, `sha256`, `partSizeLimit`,
    `githubAssetLimit` ו-`parts` (`name`, `size`, `sha256`).
  - משרשרים את החלקים לפי הסדר, למשל עם `assemble_split_asset.sh`, ובודקים את ה-sha256 של הארכיון. הסקריפט מחבר
    את החלקים בעצמו אחרי הפיצול ובודק את כל ה-sha256.

ייבוא באפליקציה צריך לתמוך בשני המצבים: לחפש קודם את `zmanenu-offline.tar.zst`, ואם אינו קיים, את
`zmanenu-offline.tar.zst.manifest.json` וחלקיו.

## ה-workflow ‏Release

Actions ← **Release** ← Run workflow, **מהענף `main` בלבד**. הרצה מענף אחר מדולגת.

| פרמטר | ברירת מחדל | משמעות |
|---|---|---|
| `release_notes` | `גרסה N` | טקסט פשוט, מוצג בחלון אישור העדכון |
| `delta_count` | `3` | לכמה גרסאות קודמות לייצר תיקון דלתא (0-4) |
| `db_version` | ריק = האחרונה + 1 | גרסה ידנית: מספר שלם, גדול מהאחרונה |
| `allow_removed_books` | כבוי | מאשר ספרים שנעלמו מהגרסה הקודמת בלי `renamedFrom`. בלי זה, Release נכשל |
| `otzaria_ref` | `otzaria-tools.ref` | הקומיט של Otzaria/otzaria שממנו נלקחים הכלים. **רק SHA מלא** של 40 תווים, לא ענף, תגית או ref של PR |
| `manifest_url_override` | ריק | **לריפו בדיקה בלבד**. ב-`Otzaria/zmanenu-library` ה-workflow נכשל אם הפרמטר מוגדר |

הקלטים עוברים לסקריפטים דרך `env`, ונבדקים לפני השימוש.

ה-workflow מחולק לארבעה jobs, כדי שכל אחד יקבל רק את ההרשאות שהוא צריך:

1. **build** (`contents: read`, בלי המפתח):
   - בדיקת הקלטים, ובדיקה ש-`update_manifest_url` שווה ל-`https://github.com/<הריפו>/releases/latest/download/manifest.json`.
   - checkout של `Otzaria/otzaria` בקומיט הנעוץ, Flutter ‏3.47.7, `flutter pub get --enforce-lockfile`, ו-`zstd`.
   - בדיקות הבונה.
   - `scripts/release_plan.py`: קובע את `db_version`, ומוריד את `delta_count` המסדים האחרונים מהרילייסים, ולפחות את
     האחרון, שממנו נשמרים מזהי הספרים. כל מסד נבנה מחדש מהחלקים ונבדק מול ה-sha256 שבמניפסט שלו.
   - בנייה עם `--release` ו-`--previous-db`: מסד בלי ספרים, ספר שנעלם בלי `renamedFrom`, או `library_id`,
     `library_folder`, כתובת המניפסט או מפתח ציבורי ששונים מהמסד הקודם, עוצרים כאן.
   - `validate_personal_db`, ו-`personal_db_update pack` עם `--delta-from`.
2. **sign** (environment ‏`release`): checkout של `signer/` ו-`library.json` בלבד, Dart, ו-
   `dart pub get --enforce-lockfile` של [`signer/`](../signer), שתלוי רק ב-`pinenacl` בגרסה נעוצה. בדיקה בבאש
   שהסוד הוא מפתח של 32 בתים ב-base64, בלי להדפיס אותו. החתימה בודקת שהמפתח תואם ל-`update_public_key`
   ושהמניפסט הוא של `library_id` ו-`db_version` הנכונים. המפתח לא נחשף לקוד האפליקציה, לתלויות שלה
   ול-`flutter test`.
3. **verify** (`contents: read`): `verify` של כלי האפליקציה, עם המפתח הציבורי שבמסד בלבד: החתימה, כל החלקים
   וכל תיקון דלתא, באותו קוד שאוצריא מריצה. אחר כך נבנית חבילת האופליין.
4. **publish** (`contents: write`, בלי checkout): מקבל את הקבצים המאומתים. מוחק טיוטות שנשארו מהרצה קודמת עם
   אותה תגית (רילייס שפורסם לעולם לא נמחק, וההרצה נכשלת), יוצר טיוטה חדשה ועובד מול המזהה שלה, מעלה את כל
   הקבצים, ורק אז מפרסם אותה כ-latest. כך `latest/download/manifest.json` אינו מצביע לרגע על רילייס חלקי.

`GH_TOKEN` מוגדר רק בשלבים שקוראים לרילייסים או מפרסמים. כל ה-actions נעוצים ל-SHA של קומיט, עם הגרסה בהערה,
וכל checkout נעשה עם `persist-credentials: false`.

ה-workflow **Check** רץ על כל push, ועל PR מ-fork (PR מענף בתוך הריפו כבר נבדק ב-push שלו). הוא מריץ את בדיקות
הבונה, `dart analyze` של הבונה ושל `signer/`, בנייה של `source/` ושל הדוגמה (`builder/test/fixtures/examples/`), ו-`validate_personal_db`. הוא
אינו מפרסם.

## הגדרות בגיטהאב (פעם אחת)

1. **Environment ‏`release`:** Settings ← Environments ← New environment ← `release`.
   - **Required reviewers:** הוסיפו את המאשרים. בלי אישור שלהם, ה-job ‏sign אינו רץ. **בלי מאשרים, כל מי שיכול
     להריץ workflows יכול לחתום בשם המסד.**
   - **Deployment branches and tags:** Selected branches ← `main`.
   - **Environment secrets:** הסוד `ZMANENU_SIGNING_KEY`, ראו בהמשך. סוד ברמת ה-environment זמין רק ל-job
     שמשויך אליו, ורק אחרי האישור.
2. **הגנה על `main`:** Settings ← Branches. Release רץ רק מ-`main`, ולכן מי שיכול לדחוף אליו קובע מה ייחתם.
3. אם הסוד הוגדר בעבר כ-repository secret, מחקו אותו משם.

## הכלים של אוצריא ב-CI

הכלים `tool/validate_personal_db.dart` ו-`tool/personal_db_update.dart` נלקחים מ-checkout של `Otzaria/otzaria`
בקומיט שנעוץ ב-[`otzaria-tools.ref`](../otzaria-tools.ref), ולא מועתקים לריפו. הנימוק:

- הכלים מייבאים קוד מ-`lib/` של האפליקציה: מפענח המניפסט, אימות החתימה ומחיל הדלתא. עותק היה סוטה בשקט מהלקוח.
  ה-checkout מבטיח ש-`verify` מריץ בדיוק את קוד הלקוח.
- המחיר: Flutter ו-`flutter pub get` של האפליקציה, כמה דקות. `subosito/flutter-action` שומר במטמון את ה-SDK
  ואת pub.
- תחזוקה: שינוי שורה אחת, `otzaria-tools.ref`, כשהכלים משתנים באפליקציה. אפשר לנסות קומיט אחר בלי קומיט,
  דרך הפרמטר `otzaria_ref`.

החתימה **אינה** משתמשת בכלי האפליקציה: היא נעשית ב-[`signer/`](../signer), בפורמט זהה (זרע של 32 בתים ב-base64,
חתימת ed25519 של 64 בתים ב-base64 ושורה חדשה). `verify` של האפליקציה בודק אותה בכל רילייס.

**מלכוד ידוע:** `dart run tool/personal_db_update.dart` אינו מתקמפל כיום, כי הוא מייבא `package:flutter/foundation`
דרך `attached_update_artifact_planner.dart` ו-`native_sha256.dart`. לכן [`scripts/otzaria-tools.sh`](../scripts/otzaria-tools.sh)
מריץ אותו כמו שהוא תחת `flutter test`, דרך קובץ בדיקה זמני שנוצר ב-checkout ונמחק בסוף. כשהאפליקציה תתקן את
זה: מעדכנים את `otzaria-tools.ref` לקומיט עם התיקון, והופכים את `dart` לברירת המחדל של `OTZARIA_UPDATE_RUNNER`
בסקריפט (או מוחקים את ענף `flutter test`). `validate_personal_db` רץ כבר עכשיו ב-`dart run`.

## מפתח החתימה

- נוצר פעם אחת ב-`personal_db_update keygen`. המפתח הפרטי נשמר מחוץ לריפו, במקום שרק המתחזקים מגיעים אליו.
  המפתח הציבורי נמצא ב-`library.json`.
- **אין החלפת מפתח.** מפתח שאבד או דלף מחייב כל משתמש להסיר את המסד ולצרף אותו מחדש. גבו את הקובץ במקום בטוח
  נוסף, למשל כונן מוצפן או מנהל סיסמאות. לעולם אל תכניסו אותו לריפו: `.gitignore` חוסם `*.key`.

### הגדרת הסוד

1. Settings ← Environments ← `release` ← Add environment secret.
2. שם: `ZMANENU_SIGNING_KEY`.
3. ערך: **כל התוכן** של קובץ המפתח הפרטי, שורה אחת ב-base64 (44 תווים).

ה-job ‏sign נכשל אם הסוד חסר, אם אינו מפתח תקין, או אם אינו המפתח שתואם ל-`update_public_key`.

## הרצה מקומית מלאה (לבדיקה)

עם checkout של אוצריא אחרי `flutter pub get`, ו-`zstd` ו-python בנתיב. השתמשו במפתח בדיקה זמני, ולא במפתח האמיתי:

```bash
export OTZARIA_DIR=/path/to/otzaria
T=/tmp/zmanenu-test
bash scripts/otzaria-tools.sh update keygen --out "$T/test.key"
# library.json זמני עם המפתח הציבורי שהודפס, אחרת verify --db נכשל כצפוי
cd builder && dart run bin/zmanenu.dart build --source ../source --library "$T/library.json" \
  --out "$T/dist" --db-version 2 --previous-db "$T/old.db" --release && cd ..
bash scripts/otzaria-tools.sh validate "$T/dist/zmanenu.db"
bash scripts/otzaria-tools.sh update pack "$T/dist/zmanenu.db" --out "$T/release" \
  --url-prefix https://github.com/Otzaria/zmanenu-library/releases/download/v2 --delta-from "$T/old.db"
(cd signer && ZMANENU_SIGNING_KEY="$(cat "$T/test.key")" dart run bin/sign.dart "$T/release/manifest.json" \
  --public-key "<המפתח הציבורי>" --library-id otzaria.zmanenu --db-version 2)
bash scripts/otzaria-tools.sh update verify "$T/release/manifest.json" --db "$T/dist/zmanenu.db" \
  --parts "$T/release" --delta-from "$T/old.db" --zstd-lib /path/to/libzstd
python3 scripts/offline_bundle.py pack --db "$T/dist/zmanenu.db" \
  --manifest "$T/release/manifest.json" --out-dir "$T/release"
```
