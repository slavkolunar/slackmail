# SlackMail

Aplikacija za gornju traku macOS-a (15 ili noviji) koja prati odabrane Slack kanale i direktne poruke i prosleđuje
nove poruke na mejl. Za svaki kanal biraš da li se prosleđuju sve poruke ili samo pominjanja
(`@ja`, `@channel`/`@everyone`, `@here`). Mejl se šalje preko tvog Gmail naloga.

## Pokretanje

```sh
scripts/build.sh                 # release build → build/SlackMail.app
open build/SlackMail.app         # ikonica se pojavljuje u gornjoj traci (nema je u Dock-u)
```

Za trajnu upotrebu prevuci `build/SlackMail.app` u `/Applications`, pa u Podešavanja → Opšte
uključi „Pokreni pri prijavi“.

## Prvo podešavanje (klik na ikonicu → Završi podešavanje)

1. **Slack nalog.** Na api.slack.com/apps izaberi Create New App → From a manifest i nalepi
   `slack-app-manifest.yaml` (dugme „Kopiraj manifest“ u aplikaciji). Zatim Install to Workspace,
   pa iz OAuth & Permissions kopiraj **User OAuth Token** (`xoxp-…`) u aplikaciju.
2. **Kanali.** Čekiraj šta pratiš i za svaki kanal izaberi pravilo.
3. **Mejl.** Unesi primaoce, Gmail adresu i app password (myaccount.google.com/apppasswords;
   traži uključenu dvostepenu potvrdu). Dugme „Pošalji probni mejl“ odmah proverava slanje.
4. Uključi **Prosleđivanje**.

## Kako radi

- Na svakih 30 s do 5 min (podesivo) čita istoriju praćenih kanala (`conversations.history`).
- Za niti aktivne u poslednjih 48 h čita samo nove odgovore (`conversations.replies`, kada se
  `latest_reply` promeni). Tako se hvataju i pominjanja u nitima.
- Poruke jednog kanala iz jednog ciklusa stižu kao **jedan mejl**, najviše 30 poruka.
- Za svaki kanal pamti dokle je stigao (`state.json`) i čuva to odmah posle svakog kanala. Ta
  tačka se pomera tek kad Gmail prihvati mejl, pa poruka ne propada ako slanje padne; pokušava se
  u sledećem ciklusu. Zaglavljena SMTP veza se prekida posle 20–30 s.
- Posle buđenja ili restarta nadoknađuje propušteno, najviše 24 h unazad. Ručno ponovno
  uključivanje prekidača kreće od „sada“.
- Greška u jednom kanalu (npr. izašao si iz kanala) ne zaustavlja ostale. Kad Slack traži pauzu
  (429), aplikacija sačeka i nastavi od kanala na kom je stala.
- Bot poruke bez teksta (GitHub, Jira, alarmi) dobijaju sadržaj iz `attachments`.
- Razmak između provera je najmanje 1,5 s po praćenom kanalu, da bi ostao ispod Slack limita.
- „Proveri sada“ i buđenje skraćuju čekanje, ali nikad ne prekidaju ciklus u toku.
- Novouključen kanal kreće od „sada“, bez slanja istorije.
- Preskače sopstvene poruke, izmene i sistemske poruke (ulazak u kanal, promena teme…).
- Prozor podešavanja se otvara samo na klik; pri pokretanju samo dok podešavanje nije završeno.
- Opcija „drži Mac budnim“ sprečava sleep zbog neaktivnosti. Zatvaranje poklopca ipak uspavljuje
  laptop, osim uz spoljni monitor.

## Bezbednost i privatnost

- Slack token i Gmail app password su samo u macOS Keychain-u. Podešavanja (bez tajni) i dnevnik
  su u `~/Library/Application Support/SlackMail/`.
- Tekst iz Slack-a se escape-uje pre ubacivanja u HTML. Iz svega što ide u zaglavlja mejla
  uklanjaju se prelomi reda, a `javascript:` i slični linkovi se ne prave.
- Prilozi se ne preuzimaju: mejl sadrži samo naziv fajla i link ka poruci u Slack-u.

## Poznata ograničenja

- Pominjanja korisničkih grupa (`@backend-tim`) ne aktiviraju pravilo „@ja“.
- Odgovori u nitima starijim od 48 h se ne hvataju.
- U jednom ciklusu se čita najviše 5 × 200 poruka po kanalu (Slack vraća najnovije prvo, pa se kod
  ekstremno prometnog kanala gube najstarije, ne najnovije).
- Ad-hoc potpis se menja pri svakom build-u, pa macOS posle rebuilda može ponovo da traži dozvolu
  za Keychain („Always Allow“).

## Provera bez mreže

```sh
build/SlackMail.app/Contents/MacOS/SlackMail --selftest        # 67 provera: filter, format, niti, kanali, MIME, SMTP, timeout
build/SlackMail.app/Contents/MacOS/SlackMail --render build/r  # PNG ikonica + popover + HTML uzorka mejla
scripts/make-icon.sh                                           # ponovo pravi Resources/AppIcon.icns
```

## Struktura

```
Sources/SlackMail/
  SlackMailApp.swift     MenuBarExtra (ikonica u traci) + prozor podešavanja
  Core/
    SlackAPI.swift       Slack Web API (auth.test, users.conversations, history, replies, users.list)
    Processor.swift      šta je novo u kanalu, niti, granica nadoknade, kursor
    Filter.swift         pravila (@ja/@channel/@here/sve) + Slack mrkdwn → HTML/tekst
    MailComposer.swift   dizajn mejla (tabele + inline CSS) i MIME
    SMTP.swift           SMTP preko TLS-a (port 465), AUTH PLAIN
    AppModel.swift       ciklus, slanje, sleep assertion, buđenje, pokretanje pri prijavi
    Keychain.swift, Storage.swift, Models.swift, SampleMail.swift
  UI/                    ikonica za traku, popover, podešavanja
```

## Licenca

MIT — vidi [LICENSE](LICENSE).
