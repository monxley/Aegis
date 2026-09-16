#!/usr/bin/env python3
"""Generate the Aegis site (docs/index.html and docs/ru/index.html).

Both languages come out of one structure so they cannot drift apart. That is
not tidiness: hreflang tells search engines these two URLs are the same page in
two languages, and a mismatch there is worse for ranking than having no
translation at all. Copy lives in LANGS; markup lives in page().

    python3 docs/build.py        # rewrites the HTML, prints what changed

The generated files are committed -- GitHub Pages serves what is in the repo,
it does not run this. Re-run it after editing copy and commit the result.
"""

import html
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).parent
BASE = "https://monxley.github.io/Aegis"
REPO = "https://github.com/monxley/Aegis"

# Every claim below is checked against the repository, not written from
# impression: the five layers are the ones in docs/screenshots/hero.jpg, the
# primitives are those in crates/aegis-crypto, and nothing is described as
# implemented that README.md's roadmap does not mark implemented.

LAYERS_KEY = ["identity", "handshake", "session", "delivery", "network"]

LANGS = {
    "en": {
        "dir": "",
        "locale": "en_US",
        "alt_locale": "ru_RU",
        "title": "Aegis — anonymous post-quantum encrypted messenger",
        "desc": (
            "Open-source messenger with no phone number and no account. "
            "Post-quantum end-to-end encryption and a Sphinx/Loopix mixnet "
            "hide what you say and who you say it to."
        ),
        "keywords": (
            "anonymous messenger, post-quantum messenger, encrypted messenger "
            "without phone number, metadata resistant messaging, mixnet, "
            "open source messenger, Sphinx onion routing, ML-KEM, Double Ratchet"
        ),
        "skip": "Skip to content",
        "nav": [("#how", "How it works"), ("#crypto", "Cryptography"),
                ("#features", "Features"), ("#fdroid", "F-Droid"), ("#node", "Run a node"),
                ("#limits", "Limits"), ("#faq", "FAQ")],
        "lang_switch": "Русский",
        "lang_switch_title": "Read this page in Russian",
        "hero_kicker": "Built on Ciphra · Post-quantum · Anonymous · Zero dependencies",
        "hero_h1_a": "Can't intercept.",
        "hero_h1_b": "Can't read.",
        "hero_h1_c": "Can't link.",
        "hero_lead": (
            "Aegis is an anonymous, end-to-end-encrypted messenger. No phone "
            "number, no email, no account on anyone's server. The relays that "
            "carry your messages cannot read them, and cannot tell who they "
            "are between."
        ),
        "cta_download": "Download for Android",
        "cta_source": "Read the source",
        "cta_fdroid": "Add the F-Droid repo",
        "fdroid_h2": "Updates without a store account",
        "fdroid_lead": (
            "Add the project's F-Droid repository and Aegis updates like any "
            "other app on your phone — no Google account, no Play Services, no "
            "sideload prompt each time. Every build there is signed with the "
            "same key as the APKs on GitHub, so you can move between the two "
            "without reinstalling."
        ),
        "cta_note": "Free and open source, Apache-2.0. Sideloaded APK — not on Google Play.",
        "alpha_title": "Alpha software.",
        "alpha_body": (
            "Aegis has not had an external security audit. The protocol and "
            "its implementation may contain flaws. Do not rely on it where "
            "being wrong would put someone in danger."
        ),
        "how_h2": "Five layers, one message",
        "how_lead": (
            "Each layer removes a different thing an observer could learn. "
            "None of them is invented here — every construction is a "
            "published design, implemented from scratch on a dependency-free "
            "cryptographic core."
        ),
        "layers": {
            "identity": ("Identity", "Stealth addressing · DH-only",
                         "recipient anonymity",
                         "Every message goes to a fresh one-time address derived "
                         "from the recipient's public key. Two messages to the "
                         "same person are unlinkable to anyone but that person. "
                         "The construction is CryptoNote's, the one Monero uses."),
            "handshake": ("Handshake", "PQXDH · X25519 + ML-KEM-768",
                          "post-quantum key agreement",
                          "The first contact agrees a key over both an elliptic "
                          "curve and a lattice. An adversary recording traffic "
                          "today to decrypt it on a future quantum computer gets "
                          "nothing, because breaking it requires breaking both."),
            "session": ("Session", "Post-quantum Double Ratchet",
                        "forward + post-compromise secrecy",
                        "Keys move forward with every message and re-key from "
                        "ML-KEM encapsulations as the conversation runs. Stealing "
                        "today's key does not open yesterday's messages, and the "
                        "session heals itself afterwards."),
            "delivery": ("Delivery", "Blind relay + sealed sender",
                         "sender anonymity · no plaintext",
                         "Messages wait in a mailbox on a relay that holds no key "
                         "to them and is not told who sent them. Run your own "
                         "relay if you would rather not take that on trust."),
            "network": ("Network", "Sphinx onion → Loopix mixnet",
                        "traffic-analysis resistance",
                        "Packets are fixed-size, layered like an onion, delayed "
                        "individually and mixed with cover traffic. An observer "
                        "watching the whole network still cannot draw the line "
                        "from you to the person you are talking to."),
        },
        "crypto_h2": "What the cryptography actually is",
        "crypto_lead": (
            "Named precisely, so it can be checked rather than believed. Every "
            "primitive is implemented from its specification with no third-party "
            "crates, and tested against the published vectors."
        ),
        "crypto_cols": ("Purpose", "Algorithm", "Specification"),
        "crypto_rows": [
            ("Key encapsulation (post-quantum)", "ML-KEM-768", "FIPS 203"),
            ("Signatures (post-quantum)", "ML-DSA-65", "FIPS 204"),
            ("Key agreement (classical)", "X25519", "RFC 7748"),
            ("Authenticated encryption", "ChaCha20-Poly1305", "RFC 8439"),
            ("Key derivation", "HKDF-SHA-256", "RFC 5869"),
            ("Hashing", "SHA-2 / SHA-3", "FIPS 180-4 / 202"),
            ("Onion packet format", "Sphinx, LIONESS payload", "Danezis–Goldberg"),
            ("Mixing and cover traffic", "Loopix", "Piotrowska et al."),
        ],
        "crypto_note": (
            "The handshake is PQXDH: X25519 and ML-KEM-768 together, so the "
            "session key survives either one being broken. This is the same "
            "shape of construction Signal deployed for the same reason."
        ),
        "features_h2": "What you get",
        "features": [
            ("No phone number, no account",
             "Your identity is a key pair generated on your device. Nothing to "
             "verify, nothing to register, nothing to take away."),
            ("24-word recovery phrase",
             "Back up the identity and restore it on another device. It is the "
             "only copy — nobody can reset it for you."),
            ("Duress password",
             "A second password opens an empty decoy account. The real one "
             "stays sealed and gives no sign it exists."),
            ("Panic wipe",
             "Hold to confirm, from the lock screen or from Settings, and the "
             "identity and history are erased."),
            ("App disguise",
             "Swap the launcher icon and name for a calculator, a notes app or "
             "a weather app."),
            ("Disappearing messages",
             "A per-chat timer, synchronised with the other side and pruned on "
             "both devices."),
            ("Safety numbers",
             "Compare a short code in person or over another channel to rule "
             "out a machine-in-the-middle."),
            ("Tor and SOCKS5, chainable",
             "Route everything through a proxy, through Tor, or through both "
             "in sequence."),
            ("Screenshot blocking",
             "Android FLAG_SECURE is on by default, and can be turned off if "
             "you would rather it were not."),
            ("Run your own nodes",
             "Point the app at infrastructure you control and route "
             "exclusively through it."),
            ("Biometric unlock",
             "Fingerprint or face over the app password, with the key held in "
             "the platform keystore."),
            ("Works in the background",
             "A foreground service keeps receiving, so messages arrive while "
             "the app is closed."),
        ],
        "shots_h2": "The app",
        "shots": [("chats.jpg", "The Aegis conversation list on Android"),
                  ("settings-security.jpg", "Aegis security settings: app lock, duress password, panic wipe"),
                  ("settings-privacy.jpg", "Aegis privacy settings: Tor and SOCKS5 proxy chain, screenshot blocking"),
                  ("nodes.jpg", "The Aegis network view, listing discovered mix nodes")],
        "node_h2": "Run a node",
        "node_lead": (
            "The network is whoever runs it. A node is a blind mailbox and a "
            "mix in one process: it stores sealed envelopes it has no key for "
            "and forwards onion packets that reveal only the previous and next "
            "hop. One command on any VPS:"
        ),
        "node_after": (
            "It builds the binary, creates a service user and starts a systemd "
            "unit. Open ports 5077 and 5078. Re-running the same command "
            "updates it in place and keeps the node's identity."
        ),
        "limits_h2": "Honest limits",
        "limits_lead": (
            "Taken from the protocol design's own non-goals. A security claim "
            "with no stated boundary is marketing."
        ),
        "limits": [
            ("No external audit",
             "Aegis is alpha and has not been reviewed by anyone outside the "
             "project. Treat every guarantee on this page as a design "
             "intention that has not yet been independently checked."),
            ("Anonymity needs a crowd",
             "You are hidden among the other people using the network at the "
             "same time. While that number is small, so is the protection. "
             "This is true of every anonymity system."),
            ("A global adversary is not solved",
             "Loopix raises the cost of traffic analysis enormously. A truly "
             "global, long-running observer remains the hardest open problem "
             "in the field. We claim strong resistance, not impossibility."),
            ("Your device is still your device",
             "If someone controls your phone while Aegis is unlocked, the "
             "messages are on the screen. No protocol fixes that."),
        ],
        "faq_h2": "Questions",
        "faq": [
            ("Do I need a phone number or an email address?",
             "No. Your identity is a key pair generated on your device the "
             "first time you open the app. There is no registration step and "
             "no account on anyone's server."),
            ("What makes it post-quantum?",
             "The handshake agrees a key using both X25519 and ML-KEM-768 "
             "(FIPS 203), and the session re-keys from further ML-KEM "
             "encapsulations as it runs. An adversary storing traffic now to "
             "decrypt later with a quantum computer would have to break the "
             "lattice scheme as well as the curve."),
            ("Can the servers read my messages?",
             "No. A relay stores sealed envelopes it holds no key for, and is "
             "not told who sent them. It also cannot tell which envelopes "
             "belong to the same recipient, because every message goes to a "
             "fresh one-time address."),
            ("How is this different from Signal?",
             "Signal encrypts message content extremely well but requires a "
             "phone number and runs on its own servers. Aegis has no phone "
             "number and no central identity, and routes traffic through a "
             "Sphinx/Loopix mixnet so that who-talks-to-whom is protected too, "
             "not only what was said."),
            ("Is it on Google Play?",
             "No. The APK is published on GitHub Releases with its SHA-256, "
             "and you install it yourself. Every release is signed with the "
             "same key — if the certificate fingerprint changes, the APK did "
             "not come from this project."),
            ("Is it really free?",
             "Yes. Apache-2.0, no accounts, no payments, no telemetry, no "
             "advertising. You can read every line and build it yourself."),
            ("Which platforms does it run on?",
             "Android today. The core is Rust and the interface is Flutter, "
             "so other platforms are possible; only Android is built and "
             "tested right now."),
        ],
        "footer_tagline": "Implement, don't invent.",
        "footer_links": [(REPO, "Source code"),
                         (REPO + "/releases", "Releases"),
                         (REPO + "/blob/main/AEGIS_PROTOCOL.md", "Protocol design"),
                         (REPO + "/blob/main/docs/CRYPTO_MATH.md", "Cryptographic details"),
                         (REPO + "/blob/main/SECURITY_AUDIT.md", "Security notes")],
        "footer_licence": "Open source under the Apache License 2.0.",
    },
    "ru": {
        "dir": "ru",
        "locale": "ru_RU",
        "alt_locale": "en_US",
        "title": "Aegis — анонимный постквантовый мессенджер",
        "desc": (
            "Мессенджер с открытым кодом без номера и без аккаунта. "
            "Постквантовое шифрование и миксеть Sphinx/Loopix скрывают и текст "
            "сообщений, и то, кто с кем переписывается."
        ),
        "keywords": (
            "анонимный мессенджер, постквантовое шифрование, мессенджер без "
            "номера телефона, защита метаданных, миксеть, мессенджер с "
            "открытым исходным кодом, луковая маршрутизация, ML-KEM"
        ),
        "skip": "Перейти к содержанию",
        "nav": [("#how", "Как устроено"), ("#crypto", "Криптография"),
                ("#features", "Возможности"), ("#fdroid", "F-Droid"), ("#node", "Свой узел"),
                ("#limits", "Границы"), ("#faq", "Вопросы")],
        "lang_switch": "English",
        "lang_switch_title": "Read this page in English",
        "hero_kicker": "На ядре Ciphra · Постквантовый · Анонимный · Без зависимостей",
        "hero_h1_a": "Не перехватить.",
        "hero_h1_b": "Не прочитать.",
        "hero_h1_c": "Не связать.",
        "hero_lead": (
            "Aegis — анонимный мессенджер со сквозным шифрованием. Без номера "
            "телефона, без почты, без аккаунта на чьём-либо сервере. Узлы, "
            "через которые идут сообщения, не могут их прочитать и не знают, "
            "между кем они."
        ),
        "cta_download": "Скачать для Android",
        "cta_source": "Открыть исходный код",
        "cta_fdroid": "Репозиторий F-Droid",
        "fdroid_h2": "Обновления без аккаунта в магазине",
        "fdroid_lead": (
            "Добавьте репозиторий проекта в F-Droid, и Aegis будет обновляться "
            "как обычное приложение — без аккаунта Google, без Play Services и "
            "без ручной установки каждый раз. Сборки там подписаны тем же "
            "ключом, что и APK на GitHub, так что переходить между ними можно "
            "без переустановки."
        ),
        "cta_note": "Бесплатно и с открытым кодом, Apache-2.0. APK ставится вручную — в Google Play его нет.",
        "alpha_title": "Альфа-версия.",
        "alpha_body": (
            "Aegis не проходил внешний аудит безопасности. В протоколе и в его "
            "реализации могут быть ошибки. Не полагайтесь на него там, где "
            "ошибка поставит кого-то под удар."
        ),
        "how_h2": "Пять слоёв, одно сообщение",
        "how_lead": (
            "Каждый слой убирает то, что иначе узнал бы наблюдатель. Ни один "
            "из них здесь не придуман: все конструкции — опубликованные "
            "схемы, реализованные с нуля на криптоядре без зависимостей."
        ),
        "layers": {
            "identity": ("Личность", "Стелс-адреса · только DH",
                         "анонимность получателя",
                         "Каждое сообщение уходит на новый одноразовый адрес, "
                         "выведенный из открытого ключа получателя. Два "
                         "сообщения одному человеку невозможно связать друг с "
                         "другом никому, кроме него самого. Конструкция — "
                         "CryptoNote, та же, что в Monero."),
            "handshake": ("Рукопожатие", "PQXDH · X25519 + ML-KEM-768",
                          "постквантовое согласование ключа",
                          "Первый контакт согласует ключ одновременно на "
                          "эллиптической кривой и на решётках. Противник, "
                          "записывающий трафик сегодня, чтобы расшифровать его "
                          "на будущем квантовом компьютере, не получит ничего: "
                          "нужно сломать обе схемы сразу."),
            "session": ("Сессия", "Постквантовый Double Ratchet",
                        "прямая и посткомпрометационная секретность",
                        "Ключи двигаются вперёд с каждым сообщением, а по ходу "
                        "переписки подмешиваются новые инкапсуляции ML-KEM. "
                        "Кража сегодняшнего ключа не открывает вчерашние "
                        "сообщения, а сессия после утечки восстанавливается."),
            "delivery": ("Доставка", "Слепой узел + запечатанный отправитель",
                         "анонимность отправителя · без открытого текста",
                         "Сообщения ждут в почтовом ящике на узле, у которого "
                         "нет ключа к ним и которому не сообщают отправителя. "
                         "Не хотите верить на слово — поднимите свой узел."),
            "network": ("Сеть", "Луковица Sphinx → миксеть Loopix",
                        "устойчивость к анализу трафика",
                        "Пакеты одного размера, завёрнуты слоями, задерживаются "
                        "поодиночке и смешиваются с прикрывающим трафиком. "
                        "Наблюдатель, видящий сеть целиком, всё равно не "
                        "проведёт линию от вас к собеседнику."),
        },
        "crypto_h2": "Что здесь за криптография",
        "crypto_lead": (
            "Названо точно, чтобы это можно было проверить, а не принять на "
            "веру. Каждый примитив реализован по спецификации без сторонних "
            "библиотек и проверен на опубликованных тестовых векторах."
        ),
        "crypto_cols": ("Назначение", "Алгоритм", "Спецификация"),
        "crypto_rows": [
            ("Инкапсуляция ключа (постквантовая)", "ML-KEM-768", "FIPS 203"),
            ("Подписи (постквантовые)", "ML-DSA-65", "FIPS 204"),
            ("Согласование ключа (классическое)", "X25519", "RFC 7748"),
            ("Аутентифицированное шифрование", "ChaCha20-Poly1305", "RFC 8439"),
            ("Вывод ключей", "HKDF-SHA-256", "RFC 5869"),
            ("Хеширование", "SHA-2 / SHA-3", "FIPS 180-4 / 202"),
            ("Формат луковицы", "Sphinx, полезная нагрузка LIONESS", "Danezis–Goldberg"),
            ("Перемешивание и прикрывающий трафик", "Loopix", "Piotrowska et al."),
        ],
        "crypto_note": (
            "Рукопожатие — PQXDH: X25519 и ML-KEM-768 вместе, чтобы ключ сессии "
            "пережил взлом любой одной из схем. Signal развернул конструкцию "
            "той же формы и по той же причине."
        ),
        "features_h2": "Что внутри",
        "features": [
            ("Без номера и без аккаунта",
             "Личность — это пара ключей, созданная на вашем устройстве. "
             "Нечего подтверждать, негде регистрироваться, нечего отобрать."),
            ("Фраза восстановления из 24 слов",
             "Резервная копия личности и перенос на другое устройство. Это "
             "единственная копия — сбросить её за вас никто не может."),
            ("Пароль под принуждением",
             "Второй пароль открывает пустой подставной аккаунт. Настоящий "
             "остаётся запечатанным и ничем себя не выдаёт."),
            ("Экстренное стирание",
             "Удержать для подтверждения — с экрана блокировки или из "
             "настроек — и личность с перепиской стираются."),
            ("Маскировка приложения",
             "Подменить иконку и название на калькулятор, заметки или погоду."),
            ("Исчезающие сообщения",
             "Таймер для каждого чата, синхронный с собеседником, чистится на "
             "обоих устройствах."),
            ("Контрольные номера",
             "Сверить короткий код лично или по другому каналу и исключить "
             "посредника в середине."),
            ("Tor и SOCKS5 цепочкой",
             "Пустить весь трафик через прокси, через Tor или через оба "
             "подряд."),
            ("Блокировка скриншотов",
             "Android FLAG_SECURE включён по умолчанию, при желании "
             "отключается."),
            ("Собственные узлы",
             "Указать приложению свою инфраструктуру и ходить только через "
             "неё."),
            ("Биометрия",
             "Отпечаток или лицо поверх пароля приложения, ключ хранится в "
             "системном хранилище."),
            ("Работает в фоне",
             "Служба переднего плана продолжает принимать, так что сообщения "
             "приходят при закрытом приложении."),
        ],
        "shots_h2": "Приложение",
        "shots": [("chats.jpg", "Список переписок Aegis на Android"),
                  ("settings-security.jpg", "Настройки безопасности Aegis: блокировка, пароль под принуждением, экстренное стирание"),
                  ("settings-privacy.jpg", "Настройки приватности Aegis: цепочка Tor и SOCKS5, блокировка скриншотов"),
                  ("nodes.jpg", "Вид сети Aegis со списком найденных микс-узлов")],
        "node_h2": "Поднять свой узел",
        "node_lead": (
            "Сеть — это те, кто её держит. Узел совмещает слепой почтовый ящик "
            "и микс: хранит запечатанные конверты, к которым у него нет ключа, "
            "и пересылает луковичные пакеты, из которых видно только "
            "предыдущий и следующий шаг. Одна команда на любом VPS:"
        ),
        "node_after": (
            "Скрипт соберёт бинарник, заведёт системного пользователя и "
            "запустит systemd-юнит. Откройте порты 5077 и 5078. Повторный "
            "запуск той же команды обновляет узел на месте и сохраняет его "
            "личность."
        ),
        "limits_h2": "Честные границы",
        "limits_lead": (
            "Взято из раздела non-goals в самом описании протокола. Заявление "
            "о безопасности без указанных границ — это реклама."
        ),
        "limits": [
            ("Внешнего аудита не было",
             "Aegis в альфе, и его не проверял никто вне проекта. Считайте "
             "каждую гарантию на этой странице проектным намерением, которое "
             "пока не подтверждено независимо."),
            ("Анонимности нужна толпа",
             "Вы скрыты среди тех, кто пользуется сетью одновременно с вами. "
             "Пока их мало — мала и защита. Так устроена любая анонимная "
             "система."),
            ("Глобальный противник не решён",
             "Loopix резко повышает стоимость анализа трафика. Действительно "
             "глобальный и долго наблюдающий противник остаётся самой трудной "
             "открытой задачей в этой области. Мы заявляем сильную "
             "устойчивость, а не невозможность."),
            ("Ваше устройство остаётся вашим устройством",
             "Если кто-то управляет вашим телефоном, пока Aegis разблокирован, "
             "сообщения у него на экране. Это не чинится протоколом."),
        ],
        "faq_h2": "Вопросы",
        "faq": [
            ("Нужен ли номер телефона или почта?",
             "Нет. Личность — это пара ключей, создаваемая на вашем устройстве "
             "при первом запуске. Регистрации нет, аккаунта на чьём-либо "
             "сервере тоже."),
            ("Что здесь постквантового?",
             "Рукопожатие согласует ключ сразу через X25519 и ML-KEM-768 "
             "(FIPS 203), а сессия по ходу работы подмешивает новые "
             "инкапсуляции ML-KEM. Противнику, который копит трафик сейчас, "
             "чтобы расшифровать его потом на квантовом компьютере, придётся "
             "сломать и решётчатую схему, и кривую."),
            ("Могут ли серверы прочитать мои сообщения?",
             "Нет. Узел хранит запечатанные конверты, к которым у него нет "
             "ключа, и не знает отправителя. Он также не может понять, какие "
             "конверты принадлежат одному получателю: каждое сообщение уходит "
             "на новый одноразовый адрес."),
            ("Чем это отличается от Signal?",
             "Signal очень хорошо шифрует содержимое, но требует номер "
             "телефона и работает на своих серверах. В Aegis нет ни номера, "
             "ни центральной личности, а трафик идёт через миксеть "
             "Sphinx/Loopix, так что защищено и то, кто с кем говорит, а не "
             "только сказанное."),
            ("Есть ли он в Google Play?",
             "Нет. APK публикуется в GitHub Releases вместе с его SHA-256, и "
             "вы ставите его сами. Каждый выпуск подписан одним и тем же "
             "ключом: если отпечаток сертификата изменился, APK пришёл не от "
             "этого проекта."),
            ("Это правда бесплатно?",
             "Да. Apache-2.0, без аккаунтов, без платежей, без телеметрии и без "
             "рекламы. Можно прочитать каждую строку и собрать самому."),
            ("На каких платформах работает?",
             "Сегодня — Android. Ядро на Rust, интерфейс на Flutter, так что "
             "другие платформы возможны; собирается и тестируется пока "
             "только Android."),
        ],
        "footer_tagline": "Реализуй, не изобретай.",
        "footer_links": [(REPO, "Исходный код"),
                         (REPO + "/releases", "Выпуски"),
                         (REPO + "/blob/main/AEGIS_PROTOCOL.md", "Описание протокола"),
                         (REPO + "/blob/main/docs/CRYPTO_MATH.md", "Криптографические детали"),
                         (REPO + "/blob/main/SECURITY_AUDIT.md", "Заметки по безопасности")],
        "footer_licence": "Открытый код под Apache License 2.0.",
    },
}

NODE_CMD = ("curl -fsSL https://raw.githubusercontent.com/monxley/Aegis/main/"
            "deploy/install.sh | sudo bash")


def e(s):
    return html.escape(s, quote=True)


def json_ld(lang, d):
    """SoftwareApplication + FAQPage.

    FAQPage is here because the questions are real ones people ask before
    installing a messenger, not keyword bait -- which is also the condition
    under which search engines keep showing it.
    """
    url = f"{BASE}/" if lang == "en" else f"{BASE}/{d['dir']}/"
    faq = ",".join(
        '{"@type":"Question","name":%s,"acceptedAnswer":'
        '{"@type":"Answer","text":%s}}' % (jstr(q), jstr(a))
        for q, a in d["faq"]
    )
    return (
        '<script type="application/ld+json">'
        '{"@context":"https://schema.org","@graph":['
        '{"@type":"SoftwareApplication","name":"Aegis",'
        '"applicationCategory":"CommunicationApplication",'
        '"operatingSystem":"Android","url":%s,"inLanguage":"%s",'
        '"description":%s,"license":"https://www.apache.org/licenses/LICENSE-2.0",'
        '"isAccessibleForFree":true,'
        '"offers":{"@type":"Offer","price":"0","priceCurrency":"USD"},'
        '"downloadUrl":"%s/releases",'
        '"softwareHelp":"%s/blob/main/AEGIS_PROTOCOL.md",'
        '"codeRepository":"%s"},'
        '{"@type":"FAQPage","inLanguage":"%s","mainEntity":[%s]}'
        ']}</script>'
    ) % (jstr(url), lang, jstr(d["desc"]), REPO, REPO, REPO, lang, faq)


def jstr(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def page(lang, d):
    other = "ru" if lang == "en" else "en"
    od = LANGS[other]
    here = f"{BASE}/" if lang == "en" else f"{BASE}/{d['dir']}/"
    there = f"{BASE}/" if other == "en" else f"{BASE}/{od['dir']}/"
    root = "" if lang == "en" else "../"

    nav = "".join(f'<a href="{h}">{e(t)}</a>' for h, t in d["nav"])

    layers = "".join(
        f'<li class="layer">'
        f'<span class="layer-n" aria-hidden="true">0{i}</span>'
        f'<div class="layer-body"><h3>{e(d["layers"][k][0])}</h3>'
        f'<p class="layer-tech">{e(d["layers"][k][1])}</p>'
        f'<p>{e(d["layers"][k][3])}</p></div>'
        f'<span class="layer-tag">{e(d["layers"][k][2])}</span></li>'
        for i, k in enumerate(LAYERS_KEY, 1)
    )

    crows = "".join(
        f"<tr><th scope=\"row\">{e(a)}</th><td><code>{e(b)}</code></td>"
        f"<td>{e(c)}</td></tr>"
        for a, b, c in d["crypto_rows"]
    )

    feats = "".join(
        f"<li><h3>{e(t)}</h3><p>{e(b)}</p></li>" for t, b in d["features"]
    )

    shots = "".join(
        f'<figure><img src="{root}screenshots/{f}" alt="{e(alt)}" '
        f'width="1968" height="2184" loading="lazy" decoding="async"></figure>'
        for f, alt in d["shots"]
    )

    limits = "".join(
        f"<li><h3>{e(t)}</h3><p>{e(b)}</p></li>" for t, b in d["limits"]
    )

    faqs = "".join(
        f"<details><summary><h3>{e(q)}</h3></summary><p>{e(a)}</p></details>"
        for q, a in d["faq"]
    )

    flinks = "".join(
        f'<li><a href="{u}">{e(t)}</a></li>' for u, t in d["footer_links"]
    )

    return f"""<!DOCTYPE html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(d['title'])}</title>
<meta name="description" content="{e(d['desc'])}">
<meta name="keywords" content="{e(d['keywords'])}">
<meta name="robots" content="index, follow, max-image-preview:large">
<meta name="theme-color" content="#0a0d12">
<link rel="canonical" href="{here}">
<link rel="alternate" hreflang="en" href="{BASE}/">
<link rel="alternate" hreflang="ru" href="{BASE}/ru/">
<link rel="alternate" hreflang="x-default" href="{BASE}/">
<link rel="icon" href="{root}assets/icon.png" type="image/png">
<link rel="apple-touch-icon" href="{root}assets/icon.png">
<link rel="stylesheet" href="{root}assets/site.css">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Aegis">
<meta property="og:title" content="{e(d['title'])}">
<meta property="og:description" content="{e(d['desc'])}">
<meta property="og:url" content="{here}">
<meta property="og:image" content="{BASE}/brand/lockup.png">
<meta property="og:image:width" content="1402">
<meta property="og:image:height" content="400">
<meta property="og:image:alt" content="Aegis — post-quantum private messenger">
<meta property="og:locale" content="{d['locale']}">
<meta property="og:locale:alternate" content="{d['alt_locale']}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{e(d['title'])}">
<meta name="twitter:description" content="{e(d['desc'])}">
<meta name="twitter:image" content="{BASE}/brand/lockup.png">
{json_ld(lang, d)}
</head>
<body>
<a class="skip" href="#main">{e(d['skip'])}</a>

<header class="site">
  <a class="brand" href="{here}">
    <img src="{root}assets/icon.png" alt="" width="32" height="32">
    <span>Aegis</span>
  </a>
  <nav aria-label="{e(d['how_h2'])}">{nav}</nav>
  <div class="head-actions">
    <a class="lang" href="{there}" hreflang="{other}" lang="{other}"
       title="{e(d['lang_switch_title'])}">{e(d['lang_switch'])}</a>
    <a class="ghost" href="{REPO}" rel="noopener">GitHub</a>
  </div>
</header>

<main id="main">

<section class="hero">
 <div class="hero-text">
  <p class="kicker">{e(d['hero_kicker'])}</p>
  <h1>{e(d['hero_h1_a'])}<br>{e(d['hero_h1_b'])}<br>
    <span class="accent">{e(d['hero_h1_c'])}</span></h1>
  <p class="lead">{e(d['hero_lead'])}</p>
  <p class="cta">
    <a class="btn primary" href="{REPO}/releases/latest" rel="noopener">{e(d['cta_download'])}</a>
    <a class="btn" href="{REPO}" rel="noopener">{e(d['cta_source'])}</a>
  </p>
  <p class="fine">{e(d['cta_note'])}</p>
  <aside class="alpha">
    <strong>{e(d['alpha_title'])}</strong> {e(d['alpha_body'])}
  </aside>
 </div>
 <div class="scene" aria-hidden="true">
  <div class="onion">
    <span class="ring r1"></span><span class="ring r2"></span>
    <span class="ring r3"></span><span class="ring r4"></span>
    <span class="ring r5"></span><span class="core"></span>
  </div>
 </div>
</section>

<section id="how">
  <h2>{e(d['how_h2'])}</h2>
  <p class="lead">{e(d['how_lead'])}</p>
  <ol class="layers">{layers}</ol>
</section>

<section id="crypto">
  <h2>{e(d['crypto_h2'])}</h2>
  <p class="lead">{e(d['crypto_lead'])}</p>
  <div class="table-wrap">
  <table>
    <thead><tr><th scope="col">{e(d['crypto_cols'][0])}</th>
      <th scope="col">{e(d['crypto_cols'][1])}</th>
      <th scope="col">{e(d['crypto_cols'][2])}</th></tr></thead>
    <tbody>{crows}</tbody>
  </table>
  </div>
  <p class="note">{e(d['crypto_note'])}</p>
</section>

<section id="features">
  <h2>{e(d['features_h2'])}</h2>
  <ul class="grid">{feats}</ul>
</section>

<section id="shots">
  <h2>{e(d['shots_h2'])}</h2>
  <div class="shots">{shots}</div>
</section>

<section id="fdroid">
  <h2>{e(d['fdroid_h2'])}</h2>
  <p class="lead">{e(d['fdroid_lead'])}</p>
  <p class="cta"><a class="btn" href="{root}fdroid/">{e(d['cta_fdroid'])}</a></p>
</section>

<section id="node">
  <h2>{e(d['node_h2'])}</h2>
  <p class="lead">{e(d['node_lead'])}</p>
  <pre><code>{e(NODE_CMD)}</code></pre>
  <p>{e(d['node_after'])}</p>
</section>

<section id="limits">
  <h2>{e(d['limits_h2'])}</h2>
  <p class="lead">{e(d['limits_lead'])}</p>
  <ul class="grid limits">{limits}</ul>
</section>

<section id="faq">
  <h2>{e(d['faq_h2'])}</h2>
  <div class="faq">{faqs}</div>
</section>

</main>

<footer class="site">
  <p class="tagline">{e(d['footer_tagline'])}</p>
  <ul class="flinks">{flinks}</ul>
  <p class="fine">{e(d['footer_licence'])}</p>
</footer>
</body>
</html>
"""


def sitemap():
    today = "2026-09-16"
    entries = []
    for lang, d in LANGS.items():
        loc = f"{BASE}/" if lang == "en" else f"{BASE}/{d['dir']}/"
        alts = "".join(
            f'<xhtml:link rel="alternate" hreflang="{l2}" '
            f'href="{BASE}/" />' if l2 == "en" else
            f'<xhtml:link rel="alternate" hreflang="{l2}" '
            f'href="{BASE}/{LANGS[l2]["dir"]}/" />'
            for l2 in LANGS
        )
        alts += f'<xhtml:link rel="alternate" hreflang="x-default" href="{BASE}/" />'
        entries.append(
            f"<url><loc>{loc}</loc>{alts}"
            f"<lastmod>{today}</lastmod><changefreq>weekly</changefreq>"
            f"<priority>{'1.0' if lang == 'en' else '0.9'}</priority></url>"
        )
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"\n'
            '        xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
            + "\n".join(entries) + "\n</urlset>\n")


def write(path, text):
    p = HERE / path
    p.parent.mkdir(parents=True, exist_ok=True)
    old = p.read_text(encoding="utf-8") if p.exists() else None
    if old == text:
        print(f"  unchanged  {path}")
        return False
    p.write_text(text, encoding="utf-8")
    print(f"  {'updated' if old else 'created'}    {path}")
    return True


def main():
    print("building the Aegis site")
    write("index.html", page("en", LANGS["en"]))
    write("ru/index.html", page("ru", LANGS["ru"]))
    write("sitemap.xml", sitemap())
    # robots.txt only takes effect at a domain root. On project pages the site
    # lives at /Aegis/, so crawlers read monxley.github.io/robots.txt instead
    # and never see this one. It is here so it is already correct if the site
    # ever moves to its own domain.
    write("robots.txt",
          "User-agent: *\nAllow: /\n\n"
          f"Sitemap: {BASE}/sitemap.xml\n")
    write(".nojekyll", "")

    # Both languages must offer the same page, or hreflang is a lie.
    en, ru = LANGS["en"], LANGS["ru"]
    for field in ("nav", "layers", "crypto_rows", "features", "shots",
                  "limits", "faq"):
        if len(en[field]) != len(ru[field]):
            sys.exit(f"EN and RU differ in '{field}': "
                     f"{len(en[field])} vs {len(ru[field])}")
    for lang, d in LANGS.items():
        if len(d["title"]) > 60:
            print(f"  WARNING  {lang} title is {len(d['title'])} chars "
                  f"(search results cut around 60)")
        if not 110 <= len(d["desc"]) <= 165:
            print(f"  WARNING  {lang} description is {len(d['desc'])} chars "
                  f"(aim for 110-165)")
    print("done")


if __name__ == "__main__":
    main()
