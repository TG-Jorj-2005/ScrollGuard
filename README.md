# ScrollGuard

Instagram pe iPhone, fără Reels. O aplicație personală: deschide instagram.com într-un WKWebView,
pe tot ecranul, și scoate tabul Reels, rafturile de Reels sugerate și vizualizatorul cu scroll
infinit. Feed-ul, profilurile, mesajele, căutarea și story-urile rămân.

Nu are backend, analytics sau conturi proprii. Te autentifici pe pagina Instagram; aplicația nu
vede și nu stochează parola. User-Agent-ul este cel implicit al WebKit.

## Instalare și actualizare (SideStore)

1. Pe iPhone, deschide în Safari `https://github.com/TG-Jorj-2005/ScrollGuard/releases/latest`
   și descarcă fișierul cu numărul versiunii în nume, de exemplu `ScrollGuard-1.0.106.ipa`.
2. Din Fișiere, apasă lung pe el → Partajează → SideStore.

Actualizarea se face la fel, iar aplicația se înlocuiește pe loc (rămâi autentificat), pentru că
identificatorul `io.github.tg-jorj-2005.scrollguard` nu se schimbă. Ce versiune rulează se vede
câteva secunde la pornire, într-o etichetă sus, și în subsolul panoului.

Atenție la Fișiere: descărcările cu același nume se adună ca `ScrollGuard 2.ipa`, și e ușor să
instalezi din nou fișierul vechi. De aceea alege fișierul cu versiunea în nume.

Limitele unui cont Apple gratuit: cel mult 3 aplicații active (cu tot cu SideStore), 10 App ID-uri
noi pe săptămână, semnătură de 7 zile (reîmprospătată din SideStore).

## Folosire

- **Ține apăsat pe marginea de sus** a ecranului (zona ceasului), sau atinge eticheta care apare
  la pornire: se deschide panoul ScrollGuard, cu cele trei comutatoare, starea contului și
  ștergerea datelor.
- **Atinge marginea de sus**: derulează la început.
- **Glisează din marginea stângă**: înapoi.

## Când ceva nu merge

Panou → **Diagnostics** → **Copy report**. Raportul conține paginile deschise (fără termeni de
căutare sau tokenuri), erorile și ce a fost blocat, plus ultimele linii din sesiunea anterioară,
utile după o închidere neașteptată. Nu conține parole sau valori de cookie.

## Dezvoltare, fără Mac

- Filtrul este în `Web/instagram.js` și `Web/instagram.css`. Testele lui rulează pe orice sistem:
  `cd tests && npm ci && npm test`.
- Aplicația (`App/`, Swift) se compilează doar în GitHub Actions: orice push pe `main` care atinge
  `App/`, `Web/`, `tests/` sau `project.yml` rulează testele, compilează și publică un Release.

## Ce este verificat și ce nu

- Verificat automat: logica filtrului, pe pagini de test (`tests/fixtures`), și compilarea.
- Neverificat automat: structura reală a instagram.com pentru un cont autentificat. Filtrul nu
  folosește clasele CSS ale Instagramului (se schimbă des), ci destinația linkurilor, dar tot
  trebuie confirmat pe telefon, cu raportul din Diagnostics.
