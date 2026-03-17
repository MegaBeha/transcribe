# transcribe

`transcribe` — это небольшой PowerShell-скрипт для автоматической расшифровки (транскрибации) аудиофайлов `.mp3` в текст через OpenAI Audio Transcriptions API.

После запуска скрипт:
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

## Возможные ошибки

- `Environment variable OPENAI_API_KEY is not set`  
  Не задан API-ключ в переменной окружения.

- `Expected .mp3 file, got: ...`  
  Передан файл не в формате `.mp3`.

- `Input file not found: ...`  
  Неверный путь к входному аудиофайлу.

---
