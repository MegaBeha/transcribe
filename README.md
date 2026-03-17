# transcribe

`transcribe` — это небольшой PowerShell-скрипт для автоматической расшифровки (транскрибации) аудиофайлов `.mp3` в текст через OpenAI Audio Transcriptions API.

После запуска скрипт:
- проверяет, что входной файл существует и имеет расширение `.mp3`;
- берёт API-ключ из переменной окружения `OPENAI_API_KEY`;
- отправляет аудио в модель `gpt-4o-mini-transcribe`;
- сохраняет результат в `.txt` рядом с исходным файлом.

Например: `meeting.mp3` → `meeting.txt`.

---

## Требования

- **PowerShell**:
  - Windows PowerShell 5.1+ или
  - PowerShell 7+
- Доступ в интернет
- API-ключ OpenAI
- Аудиофайл в формате **`.mp3`**

---

## Быстрый запуск

Из папки проекта:

```powershell
./transcribe.ps1 ./audio/example.mp3
```

Если скрипты запрещены политикой выполнения, можно запустить так:

```powershell
powershell -ExecutionPolicy Bypass -File .\transcribe.ps1 .\audio\example.mp3
```

или для PowerShell 7:

```powershell
pwsh -ExecutionPolicy Bypass -File ./transcribe.ps1 ./audio/example.mp3
```

---

## Как правильно добавить токен в переменную окружения

Скрипт читает ключ **только** из переменной `OPENAI_API_KEY`.

### Windows (PowerShell) — на текущую сессию

Подходит для разового запуска в открытом окне терминала:

```powershell
$env:OPENAI_API_KEY = "ваш_токен_здесь"
```

Проверка:

```powershell
$env:OPENAI_API_KEY
```

> После закрытия окна терминала значение исчезнет.

### Windows (PowerShell) — на постоянной основе для пользователя

```powershell
[Environment]::SetEnvironmentVariable("OPENAI_API_KEY", "ваш_токен_здесь", "User")
```

После этого **перезапустите терминал** и проверьте:

```powershell
$env:OPENAI_API_KEY
```

### macOS / Linux (bash, zsh)

Временный вариант (до закрытия терминала):

```bash
export OPENAI_API_KEY="ваш_токен_здесь"
```

Проверка:

```bash
echo "$OPENAI_API_KEY"
```

Чтобы сделать переменную постоянной, добавьте команду `export` в `~/.bashrc`, `~/.zshrc` или другой файл инициализации вашей оболочки.

---

## Пример полного сценария (Windows PowerShell)

```powershell
# 1) Один раз задаём переменную среды
$env:OPENAI_API_KEY = "ваш_токен_здесь"

# 2) Запускаем транскрибацию
./transcribe.ps1 .\records\interview.mp3

# 3) Получаем файл .\records\interview.txt
```

---

## Возможные ошибки

- `Environment variable OPENAI_API_KEY is not set`  
  Не задан API-ключ в переменной окружения.

- `Expected .mp3 file, got: ...`  
  Передан файл не в формате `.mp3`.

- `Input file not found: ...`  
  Неверный путь к входному аудиофайлу.

---

## Безопасность

- Не храните токен прямо в коде.
- Не коммитьте токен в Git.
- При случайной утечке токена — немедленно перевыпустите (rotate) ключ.
