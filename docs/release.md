# הוצאת גרסה, מפתח חתימה ועדכונים

## איך עדכון מגיע למשתמש

1. במסד שאצל המשתמש כתובים `update_manifest_url` ו-`update_public_key` (מ-`library.json`). אוצריא נועצת אותם
   בפעם הראשונה שהיא רואה את המסד.
2. אוצריא מורידה את `https://github.com/Otzaria/zmanenu-library/releases/latest/download/manifest.json` ואת
   `manifest.json.sig` מאותה כתובת, ובודקת את החתימה מול המפתח הנעוץ. GitHub מפנה את `latest/download` לרילייס
   האחרון שאינו טיוטה, והלקוח עוקב אחרי עד 5 הפניות ובודק כל אחת מהן.
3. אם `db_version` במניפסט גדול מהמותקן, מוצע עדכון. הלקוח מעדיף תיקון דלתא מהגרסה המותקנת, ובכל כשל חוזר
   לקובץ המלא. החלקים יושבים בכתובות קבועות של הרילייס: `releases/download/vN/...`.

## ה-workflow ‏Release

Actions ← **Release** ← Run workflow (`workflow_dispatch` בלבד):

| פרמטר | ברירת מחדל | משמעות |
|---|---|---|
| `release_notes` | `גרסה N` | טקסט פשוט, מוצג בחלון אישור העדכון |
| `delta_count` | `3` | לכמה גרסאות קודמות לייצר תיקון דלתא (0-4) |
| `db_version` | ריק = האחרונה + 1 | גרסה ידנית; חייבת להיות גדולה מהאחרונה |
| `otzaria_ref` | `otzaria-tools.ref` | הקומיט של Otzaria/otzaria שממנו נלקחים הכלים |
| `manifest_url_override` | ריק | **לריפו בדיקה בלבד**. בריפו האמיתי ה-workflow נכשל אם הכתובת ב-`library.json` אינה הכתובת של הריפו |

השלבים:

1. בדיקה ש-`update_manifest_url` ב-`library.json` שווה ל-`https://github.com/<הריפו>/releases/latest/download/manifest.json`, ושהסוד מוגדר.
2. checkout של `Otzaria/otzaria` בקומיט הנעוץ, Flutter ‏3.47.7, `flutter pub get`, ו-`zstd`.
3. בדיקות הבונה.
4. `scripts/release_plan.py`: קובע את `db_version`, ומוריד את `delta_count` המסדים האחרונים מהרילייסים, ולפחות את
   האחרון, שממנו נשמרים מזהי הספרים. כל מסד נבנה מחדש מהחלקים ונבדק מול ה-sha256 שבמניפסט שלו.
5. בנייה של `source/` עם `--previous-db` ו-`--db-version`.
6. `validate_personal_db`.
7. `personal_db_update pack` עם `--delta-from` לכל גרסה קודמת. החלקים מקבלים כתובות `releases/download/vN/`.
8. `sign` עם הסוד. המפתח נכתב לקובץ זמני בהרשאות 600 ונמחק מיד אחרי השלב.
9. `verify` של החתימה, החלקים ושל **כל** תיקון דלתא, באותו קוד שאוצריא מריצה.
10. `zmanenu.zip`: המסד ותיקיית `zmanenu-files`, להתקנה ראשונה ידנית.
11. `gh release create vN` כטיוטה עם כל הקבצים, ואז פרסום כ-latest. כך `latest/download/manifest.json` אינו
    מצביע לרגע על רילייס חלקי.

ה-workflow **Check** רץ על כל push ו-PR, וגם ידנית: בדיקות, בנייה של `source/` ושל `examples/`, ו-`validate_personal_db`. הוא אינו מפרסם.

**חובה לשמור את הרילייסים הישנים.** הבנייה הבאה מורידה מהם את המסד הקודם (מזהי ספרים ודלתות), ומשתמשים
בגרסאות ישנות מורידים מהם את חלקי הדלתא.

## הכלים של אוצריא ב-CI

הכלים `tool/validate_personal_db.dart` ו-`tool/personal_db_update.dart` נלקחים מ-checkout של `Otzaria/otzaria`
בקומיט שנעוץ ב-[`otzaria-tools.ref`](../otzaria-tools.ref), ולא מועתקים לריפו. הנימוק:

- הכלים מייבאים קוד מ-`lib/` של האפליקציה: מפענח המניפסט, החתימה ומחיל הדלתא. עותק היה סוטה בשקט מהלקוח. ה-checkout מבטיח
  ש-`verify` מריץ בדיוק את קוד הלקוח.
- המחיר: Flutter ו-`flutter pub get` של האפליקציה, כמה דקות. `subosito/flutter-action` שומר במטמון את ה-SDK
  ואת pub. ב-Release, שרץ ידנית ולעיתים רחוקות, זה זניח. ב-Check זה המחיר של אימות אמיתי.
- תחזוקה: שינוי שורה אחת, `otzaria-tools.ref`, כשהכלים משתנים באפליקציה. אפשר לנסות ref אחר בלי קומיט, דרך הפרמטר `otzaria_ref`.

**מלכוד ידוע:** `dart run tool/personal_db_update.dart` אינו מתקמפל כיום, כי הוא מייבא `package:flutter/foundation`
דרך `attached_update_artifact_planner.dart` ו-`native_sha256.dart`. לכן [`scripts/otzaria-tools.sh`](../scripts/otzaria-tools.sh)
מריץ אותו כמו שהוא תחת `flutter test`, דרך קובץ בדיקה זמני שנוצר ב-checkout. כשהאפליקציה תתקן את זה, מגדירים
`OTZARIA_UPDATE_RUNNER=dart`, או מוחקים את הענף הזה בסקריפט. `validate_personal_db` רץ כבר עכשיו ב-`dart run`.

## מפתח החתימה

- נוצר פעם אחת ב-`personal_db_update keygen`. המפתח הפרטי נשמר מחוץ לריפו, ב-`D:/Otzaria/zmanenu-keys/zmanenu-signing.key`.
  המפתח הציבורי נמצא ב-`D:/Otzaria/zmanenu-keys/public_key.txt` וב-`library.json`.
- **אין החלפת מפתח.** מפתח שאבד או דלף מחייב כל משתמש להסיר את המסד ולצרף אותו מחדש. גבו את הקובץ במקום בטוח
  נוסף, למשל כונן מוצפן או מנהל סיסמאות. לעולם אל תכניסו אותו לריפו: `.gitignore` חוסם `*.key`.

### הגדרת הסוד

1. בריפו בגיטהאב: Settings ← Secrets and variables ← Actions ← New repository secret.
2. שם: `ZMANENU_SIGNING_KEY`.
3. ערך: **כל התוכן** של `zmanenu-signing.key`, שורה אחת ב-base64.
4. רצוי לצמצם את מי שיכול להריץ workflows ולהגן על `main` (Settings ← Branches), כי כל מי שמריץ Release חותם בשם המסד.

`verify` בסוף ה-workflow נכשל אם הסוד אינו המפתח שתואם ל-`update_public_key`.

## הרצה מקומית מלאה (לבדיקה)

עם checkout של אוצריא אחרי `flutter pub get`, ו-`zstd` ו-`python3` בנתיב:

```bash
export OTZARIA_DIR=/path/to/otzaria
cd builder && dart run bin/zmanenu.dart build --source ../source --out ../dist --db-version 2 --previous-db old.db && cd ..
bash scripts/otzaria-tools.sh validate "$PWD/dist/zmanenu.db"
bash scripts/otzaria-tools.sh update pack "$PWD/dist/zmanenu.db" --out "$PWD/release" \
  --url-prefix https://github.com/Otzaria/zmanenu-library/releases/download/v2 --delta-from "$PWD/old.db"
bash scripts/otzaria-tools.sh update sign "$PWD/release/manifest.json" --key /path/to/test.key
bash scripts/otzaria-tools.sh update verify "$PWD/release/manifest.json" --db "$PWD/dist/zmanenu.db" \
  --parts "$PWD/release" --delta-from "$PWD/old.db" --zstd-lib /path/to/libzstd
```

לבדיקה מקומית עם מפתח זמני צריך גם `library.json` זמני עם המפתח הציבורי שלו, אחרת `verify --db` נכשל כצפוי.
