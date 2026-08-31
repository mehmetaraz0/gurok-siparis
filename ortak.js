// ortak.js — bar.html ve depo.html'in PAYLAŞTIĞI mantık.
//
// Excel üretimi burada TEK bir yerde durur. Eski tek-dosya sürümde aynı kurgu
// dlExcel() ve dlAllExcel() içinde iki ayrı kopya halindeydi; biri değişince
// çıktılar sessizce ayrışabiliyordu. Artık bar da depo da aynı fonksiyonu
// çağırdığı için üretilen xlsx birebir aynıdır.

/* ---------- Supabase ---------- */

const SB = supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);

/* ---------- Yardımcılar ---------- */

// XML'e yazılacak metni kaçışlar.
// Katalogda & içeren 33 ürün var (ICE TEA MANGO&ANANAS, CHIWAS SMOOTH&SMOKY,
// KOKTEYL MIX PETBUER&ALMON). Kaçışlanmazsa sheet1.xml bozulur ve Excel
// dosyayı "onarılması gerekiyor" diyerek açmaz.
function xmlEsc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// HTML'e basılacak metni kaçışlar. Tek tırnak da kaçışlanır; ama inline
// onclick gibi bir yerde tek başına yeterli DEĞİLDİR (tarayıcı entity'yi JS
// ayrıştırmasından önce çözer), o yüzden dinamik değerler onclick string'ine
// gömülmez — data-* + addEventListener kullanılır.
function htmlEsc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// Tarayıcı saat dilimine bakmaksızın Türkiye tarihi (YYYY-AA-GG).
function bugun() {
  return new Date().toLocaleDateString("sv-SE", { timeZone: "Europe/Istanbul" });
}

function saat(ts) {
  return new Date(ts).toLocaleTimeString("tr-TR", {
    timeZone: "Europe/Istanbul", hour: "2-digit", minute: "2-digit"
  });
}

// "14.08 09:15" — envanterde birden çok güne bakıldığı için gün de gerekli
function tarihSaat(ts) {
  if (!ts) return "—";
  const d = new Date(ts);
  return d.toLocaleDateString("tr-TR", { timeZone: "Europe/Istanbul", day: "2-digit", month: "2-digit" })
       + " " + saat(ts);
}

/* ---------- Düzenlenebilir katalog ---------- */

// Liste kimliği: bar için outlet kodu, mutfak için "kod|bölüm"
function listeKimlik(kod, bolum) {
  return bolum ? kod + "|" + bolum : kod;
}

/* Kimlik hatası artık exception DEĞİL, {ok:false, hata} nesnesi olarak döner.
   Sebep: sunucuda başarısız PIN denemesi kaptan_deneme'ye yazılıyor; raise
   exception transaction'ı geri alır ve o kayıt da silinirdi (bkz. kurulum.sql
   kaptan_dogrula notu). Dolayısıyla PIN alan HER RPC çağrısı dönen değeri
   bu süzgeçten geçirmeli — yoksa hata sessizce "veri" sanılır.
   Dizi dönen fonksiyonlarda (katalog_getir, stok_gizli_kodlar,
   bekleyen_siparisler) nesne gelmesi zaten kimlik hatası demektir. */
function rpcKimlikHatasi(data) {
  return (data && !Array.isArray(data) && typeof data === "object" && data.ok === false)
    ? (data.hata || "Yetki gerekli")
    : null;
}

// Bir listenin ürünlerini buluttan çeker. Bulut boşsa/ulaşılamazsa null döner
// Bulut katalogu. Kimlik ŞART (kaptan PIN'i ya da admin şifresi).
// kimlik = {kod, pin} (kaptan) veya {sifre} (admin).
// SQL henüz uygulanmamış veritabanlarında yeni imza bulunamaz; o durumda eski
// tek-argümanlı çağrıya düşülür (geçiş penceresi; SQL uygulanınca bu dal ölür).
async function katalogGetir(liste, kimlik) {
  const arg = { p_liste: liste };
  if (kimlik && kimlik.kod && kimlik.pin) { arg.p_kaptan_kod = kimlik.kod; arg.p_kaptan_pin = kimlik.pin; }
  if (kimlik && kimlik.sifre) arg.p_sifre = kimlik.sifre;
  try {
    let { data, error } = await SB.rpc("katalog_getir", arg);
    if (error && /does not exist|Could not find/i.test(error.message || "")) {
      ({ data, error } = await SB.rpc("katalog_getir", { p_liste: liste }));   // eski imza
    }
    if (error) throw error;
    const kh = rpcKimlikHatasi(data);
    if (kh) throw new Error(kh);
    return (Array.isArray(data) && data.length) ? data : null;
  } catch (e) {
    console.error("katalog_getir:", e.message || e);
    return null;
  }
}

// Statik veri.js/mutfak.js'ten tüm liste kimliklerini ve kalemlerini üretir
// (admin tohumlaması için). Dönen: [{liste, kalemler:[{k,a,b,g,sira}]}]
function statikListeler() {
  const out = [];
  if (typeof D !== "undefined") {
    D.forEach(o => {
      const sirali = grupluSirala(o.i).map((i, n) => ({ k: i.k, a: i.a, b: i.b, g: i.g, sira: n }));
      out.push({ liste: o.c, kalemler: sirali });
    });
  }
  if (typeof M !== "undefined" && typeof MUTFAK_LISTE !== "undefined") {
    M.forEach(m => m.b.forEach(bolum => {
      const liste = MUTFAK_LISTE[bolum] || [];
      const sirali = grupluSirala(liste, mutfakKatIndex).map((i, n) => ({ k: i.k, a: i.a, b: i.b, g: i.g, sira: n }));
      out.push({ liste: m.c + "|" + bolum, kalemler: sirali });
    }));
  }
  return out;
}

/* ---------- Stok ---------- */

// Bar + mutfak katalogundaki tüm ürün kodları. Stok yalnızca bu kalemler için
// tutulur; KUM raporundaki sipariş dışı gruplar (GNL01 aktivite vb.) elenir.
let _katalogSet = null;
function katalogKodlari() {
  if (_katalogSet) return _katalogSet;
  const s = new Set();
  if (typeof D !== "undefined") D.forEach(o => o.i.forEach(i => s.add(i.k)));
  if (typeof MUTFAK_LISTE !== "undefined")
    Object.values(MUTFAK_LISTE).flat().forEach(i => s.add(i.k));
  _katalogSet = s;
  return s;
}

// Türk sayı biçimi: "48.000,00" → 48000 ; "-2,00" → -2 ; düz "48000" → 48000
function trNum(s) {
  s = String(s ?? "").trim();
  if (s === "") return null;
  if (s.includes(",")) return parseFloat(s.replace(/\./g, "").replace(",", "."));
  const n = parseFloat(s);
  return isNaN(n) ? null : n;
}

// KUM raporu metin satırlarından kalem çıkarır (PDF ve satır-birleştirilmiş Excel).
// Satır: KOD  AD...  BİRİM  d0 d1 .. d9   (10 sayı; d1=Giriş Satın Alma, d9=Kalan)
// Dönen: [{k, a, b, kalan, gelen}]
function kumParse(satirlar) {
  const KOD = /^([A-Z]{3}\d{8})\s+(.+)$/;
  const NUM = /^-?[\d.]*\d(?:,\d+)?$|^-?\d+(?:\.\d+)?$/;
  const out = [];
  for (const raw of satirlar) {
    const t = String(raw ?? "").replace(/\s+/g, " ").trim();
    const m = t.match(KOD);
    if (!m) continue;
    const parca = m[2].split(" ");
    if (parca.length < 11) continue;
    const sayilar = parca.slice(-10);
    if (!sayilar.every(x => NUM.test(x))) continue;
    const birim = parca[parca.length - 11];
    const ad = parca.slice(0, parca.length - 11).join(" ");
    const v = sayilar.map(trNum);
    out.push({ k: m[1], a: ad, b: birim, kalan: v[9], gelen: v[1] });
  }
  return out;
}

// Bar/mutfak: stoğu 0/negatif olan kod kümesi. Stok modülü yoksa boş küme
// döner (hiçbir ürün gizlenmez), böylece sistem eskisi gibi çalışmaya devam eder.
async function stokGizliYukle(kaptan) {
  if (!kaptan || !kaptan.kod || !kaptan.pin) return new Set();   // kimlik yoksa sorgulama
  try {
    const { data, error } = await SB.rpc("stok_gizli_kodlar",
      kaptanArg(kaptan));
    if (error) throw error;
    const kh = rpcKimlikHatasi(data);
    if (kh) throw new Error(kh);
    return new Set(data || []);
  } catch (e) {
    console.error("stok_gizli_kodlar:", e.message || e);
    return new Set();
  }
}


/* Tarayıcı deposundan (localStorage/sessionStorage) gelen "kod -> miktar" haritasını
   TEMİZLER. Depo kullanıcı tarafından değiştirilebilir; oradan gelen değer doğrudan
   HTML attribute'una yazılırsa (value="...") attribute enjeksiyonuna açık olur.
   Yalnızca geçerli kalem kodu + pozitif tam sayı geçer. */
function miktarHaritasiTemizle(obj) {
  const temiz = {};
  if (!obj || typeof obj !== "object") return temiz;
  for (const k of Object.keys(obj)) {
    if (!/^[A-Z]{3}[0-9]{8}$/.test(k)) continue;          // kod deseni
    const v = Number(obj[k]);
    if (Number.isInteger(v) && v > 0 && v <= 100000) temiz[k] = v;
  }
  return temiz;
}


/* ---------- Oturum token'ı ----------
   Şifre/PIN artık yalnızca giriş çağrısında gider; sonrasında kısa ömürlü token
   kullanılır. Token sunucuda iptal edilebilir ve süresi dolar.
   GEÇİŞ: veritabanı henüz güncellenmediyse giriş fonksiyonu bulunamaz; o durumda
   eski şifre/PIN parametrelerine düşülür (TOKEN_MODU=false). SQL uygulandıktan
   sonra bu dal ölür ve temizlenebilir. */
let TOKEN = null;
let TOKEN_MODU = false;

// RPC'nin veritabanında bulunmadığını anlatan hata mı?
function rpcYok(error) {
  return !!error && /does not exist|Could not find/i.test(error.message || "");
}

// Depo/admin çağrıları için yetki argümanı
function yetkiArg(eskiSifre) {
  return TOKEN_MODU ? { p_token: TOKEN } : { p_sifre: eskiSifre };
}

// Kaptan çağrıları için yetki argümanı
function kaptanArg(kaptan) {
  if (TOKEN_MODU && TOKEN) return { p_token: TOKEN };
  return kaptan ? { p_kaptan_kod: kaptan.kod, p_kaptan_pin: kaptan.pin } : {};
}

// Şifreyle giriş: önce token modeli denenir, yoksa eski yola düşülür.
//   girisRpc : "depo_giris" | "admin_giris"
//   eskiDogrula: token yoksa şifreyi doğrulayan geri-uyum fonksiyonu (async)
// Dönüş: { ok, hata }
async function sifreIleGiris(girisRpc, sifre, eskiDogrula) {
  try {
    const { data, error } = await SB.rpc(girisRpc, { p_sifre: sifre });
    if (!error && data && data.ok && data.token) {
      TOKEN = data.token; TOKEN_MODU = true;
      return { ok: true };
    }
    if (!error && data && data.ok === false) return { ok: false, hata: data.hata || "Şifre hatalı." };
    if (!rpcYok(error)) return { ok: false, hata: "Şifre hatalı." };
  } catch (e) { return { ok: false, hata: "Bağlantı kurulamadı." }; }
  // Eski veritabanı: token yok
  TOKEN = null; TOKEN_MODU = false;
  return await eskiDogrula();
}

// Token'ı sekme oturumunda sakla. TOKEN MODUNDA ŞİFRE/PIN SAKLANMAZ:
// süreli ve sunucudan iptal edilebilir token, düz şifreden çok daha güvenli.
function tokenKaydet(anahtar) {
  try {
    if (TOKEN_MODU && TOKEN) sessionStorage.setItem(anahtar + "_token", TOKEN);
    else sessionStorage.removeItem(anahtar + "_token");
  } catch (e) {}
}

// Sekme oturumundan token'ı geri yükle. Döner: token bulundu mu?
function tokenGeriYukle(anahtar) {
  try {
    if (!oturumTaze(anahtar)) return false;
    const t = sessionStorage.getItem(anahtar + "_token");
    if (!t) return false;
    TOKEN = t; TOKEN_MODU = true; return true;
  } catch (e) { return false; }
}

async function oturumuKapat() {
  if (TOKEN_MODU && TOKEN) { try { await SB.rpc("oturum_iptal", { p_token: TOKEN }); } catch (e) {} }
  TOKEN = null; TOKEN_MODU = false;
}
/* ---------- Oturum süresi ----------
   Paylaşılan tablette sekme hiç kapanmıyor; damgasız oturum sabah giren kişinin
   adına akşam sipariş gitmesine yol açar. Girişler MUTLAK süreyle sınırlanır. */
const OTURUM_SAAT = 12;

function oturumDamgala(anahtar) {
  try { sessionStorage.setItem(anahtar + "_zaman", String(Date.now())); } catch (e) {}
}

function oturumTaze(anahtar) {
  try {
    const t = Number(sessionStorage.getItem(anahtar + "_zaman") || 0);
    return t > 0 && (Date.now() - t) < OTURUM_SAAT * 3600 * 1000;
  } catch (e) { return false; }
}
/* ---------- Onaylanan miktar ---------- */

// Bir kalemin Excel'e girecek miktarı.
// m = barın talep ettiği, o = deponun onayladığı (yoksa talep geçerli).
function gecerliMiktar(it) {
  return (it.o === undefined || it.o === null) ? it.m : it.o;
}

// Excel'e girecek kalemler: onaylanan miktar 0 olanlar (verilmeyen ürünler) çıkarılır,
// kalanların miktarı onaylanan değere sabitlenir.
function excelKalemleri(kalemler) {
  return kalemler
    .map(it => ({ ...it, m: gecerliMiktar(it) }))
    .filter(it => it.m > 0);
}

/* ---------- Excel üretimi ---------- */

// kalemler: [{k: kod, a: ad, b: birim, m: miktar}, ...]
// Dönen değer: xlsx Blob'u
async function buildExcelBlob(outletKod, outletAd, kalemler) {
  const tplBytes = Uint8Array.from(atob(TPL_B64), c => c.charCodeAt(0));
  const zip = await JSZip.loadAsync(tplBytes);
  let sheet = await zip.file("xl/worksheets/sheet1.xml").async("string");

  // Şablondaki örnek satırı çıkar
  sheet = sheet.replace(/<row r="2">.*?<\/row>/s, "");

  let newRows = "";
  for (let i = 0; i < kalemler.length; i++) {
    const it = kalemler[i];
    const rn = i + 2;

    let row = ROW2.replace(/r="2"/g, 'r="' + rn + '"');
    row = row.replace(/r="([A-Z]{1,2})2"/g, 'r="$1' + rn + '"');

    const hucre = (sut, icerik) => {
      row = row.replace(new RegExp('<c r="' + sut + rn + '"[^>]*>.*?</c>'), icerik);
    };

    hucre("V",  '<c r="V'  + rn + '" t="inlineStr"><is><t>' + xmlEsc(outletKod) + '</t></is></c>');
    hucre("W",  '<c r="W'  + rn + '" t="inlineStr"><is><t>' + xmlEsc(outletAd)  + '</t></is></c>');
    hucre("AQ", '<c r="AQ' + rn + '" t="n" s="15"><v>' + (i + 1) + '</v></c>');
    hucre("AS", '<c r="AS' + rn + '" t="n" s="15"><v>1</v></c>');
    hucre("AU", '<c r="AU' + rn + '" t="inlineStr"><is><t>' + xmlEsc(it.k) + '</t></is></c>');
    hucre("AV", '<c r="AV' + rn + '" t="inlineStr"><is><t>' + xmlEsc(it.a) + '</t></is></c>');
    hucre("AW", '<c r="AW' + rn + '" t="n"><v>' + it.m + '.0</v></c>');
    hucre("AX", '<c r="AX' + rn + '" t="inlineStr"><is><t>' + xmlEsc(it.b) + '</t></is></c>');
    hucre("AY", '<c r="AY' + rn + '" t="n"><v>' + it.m + '.0</v></c>');
    hucre("AZ", '<c r="AZ' + rn + '" t="inlineStr"><is><t>' + xmlEsc(it.b) + '</t></is></c>');

    newRows += row + "\n";
  }

  sheet = sheet.replace("</sheetData>", newRows + "</sheetData>");
  sheet = sheet.replace(/dimension ref="[^"]*"/, 'dimension ref="A1:BI' + (kalemler.length + 1) + '"');
  zip.file("xl/worksheets/sheet1.xml", sheet);

  return await zip.generateAsync({
    type: "blob",
    mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  });
}

// Excel'i üretip indirir. Onaylanan miktarlar uygulanır, verilmeyen kalemler düşer.
// Dosya adı: siparis_SIP-20260814-007_CSM315.xlsx  (sipariş no yoksa tarih kullanılır)
async function indirExcel(outletKod, outletAd, kalemler, etiket) {
  const secilen = excelKalemleri(kalemler);
  if (!secilen.length) throw new Error("Onaylanan kalem yok");

  const blob = await buildExcelBlob(outletKod, outletAd, secilen);
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "siparis_" + (etiket || bugun()) + "_" + outletKod + ".xlsx";
  a.click();
  URL.revokeObjectURL(url);
}

/* ---------- Katalog yardımcıları ---------- */

// Outlet kodundan outlet nesnesi
function outletBul(kod) {
  return D.find(o => o.c === kod) || null;
}

// Ekranda gösterilen kısa kod: CSM315 → B315 (bar), CMM201 → M201 (mutfak)
function kisaKod(kod) {
  kod = String(kod || "");
  if (kod.startsWith("CMM")) return "M" + kod.slice(3);
  if (kod.startsWith("CSM")) return "B" + kod.slice(3);
  return kod.slice(3);
}

// "M201 ANAMUTFAK · KAHVALTI" / "315 PAVILLION BAR"
function birimAdi(kod, ad, bolum) {
  return kisaKod(kod) + " " + (ad || "") + (bolum ? " · " + bolum : "");
}

// Grup rengi sınıfı (g0..g7 / gd)
function grupSinifi(g) {
  return "g" + (GC[g] ?? "d");
}

/* ---------- Grup sırası ----------
   Katalog ürün KODUNA göre sıralı, gruba göre değil. Bu yüzden ham sırayla
   basıldığında aynı grup listede birkaç kez başlık alıyordu: PREMIX SODA
   ICA01 ailesinde, PREMIX KOLA ICA02 ailesinde olduğu için PREMIX üç ayrı
   yerde çıkıyordu; CSM301'de CARTE D'OR dört, ALGIDA beş ayrı yerdeydi.

   Sıra iki kademeli: önce GC'deki renk kümesi (alkolsüz → alkollü → servis →
   yiyecek → temizlik → hijyen → dondurma → atıştırmalık), sonra GC içindeki
   tanım sırası. Böylece dondurma alt grupları da art arda gelir. */

const GRUP_INDEX = (() => {
  const anahtarlar = Object.keys(GC);
  const tanimSirasi = {};
  anahtarlar.forEach((g, n) => { tanimSirasi[g] = n; });

  const sirali = anahtarlar.slice().sort(
    (a, b) => (GC[a] - GC[b]) || (tanimSirasi[a] - tanimSirasi[b])
  );

  const index = {};
  sirali.forEach((g, n) => { index[g] = n; });
  return index;
})();

// GC'de tanımsız bir grup çıkarsa listenin sonuna düşer (kaybolmaz)
function grupIndex(g) {
  return (g in GRUP_INDEX) ? GRUP_INDEX[g] : 9999;
}

// Bir kod stokta izlenebilir mi? Yiyecek/içecek (YIY/ICA/ICB) her zaman izlenir
// (sipariş katalogunda olmasa bile — sadece stok görünür, sipariş edilemez).
// Diğer aileler (GNL genel/malzeme, DIG diğer) yalnızca katalogda ise izlenir.
function stokUygun(kod) {
  return /^(YIY|ICA|ICB)[0-9]/.test(kod) || katalogKodlari().has(kod);
}

/* ---------- Mutfak kategorileri ----------
   Mutfak listelerinin kategorisi ürün kodundan türetilir (bkz. mutfak.js).
   Bar grupları GC'den, mutfak kategorileri MUTFAK_KAT'tan sıralanır. */

function mutfakKatIndex(g) {
  return (typeof MUTFAK_KAT !== "undefined" && MUTFAK_KAT[g]) ? MUTFAK_KAT[g].s : 999;
}

function mutfakKatSinifi(g) {
  const r = (typeof MUTFAK_KAT !== "undefined" && MUTFAK_KAT[g]) ? MUTFAK_KAT[g].r : 9;
  return r === 9 ? "gd" : "g" + r;
}

// Kalemleri gruba göre öbekler. Dönen değer: [[grupAdı, [kalem, ...]], ...]
// Her grup TEK blok; grup içi ürün adına göre. Sıralama ölçütü dışarıdan
// verilebilir: bar listeleri grupIndex, mutfak listeleri mutfakKatIndex kullanır.
function grupla(kalemler, indexFn) {
  const idx = indexFn || grupIndex;
  const gruplar = new Map();
  kalemler.forEach(it => {
    const g = it.g || "DİĞER";
    if (!gruplar.has(g)) gruplar.set(g, []);
    gruplar.get(g).push(it);
  });

  return [...gruplar.entries()]
    .sort((a, b) => (idx(a[0]) - idx(b[0])) || a[0].localeCompare(b[0], "tr"))
    .map(([g, list]) => [g, list.slice().sort(kalemSirala)]);
}

// Grup içi sıra: elle sıra (sira) verilmişse ona göre, yoksa ürün adına göre.
function kalemSirala(x, y) {
  const sx = x.sira, sy = y.sira;
  if (sx != null && sy != null && sx !== sy) return sx - sy;
  return x.a.localeCompare(y.a, "tr");
}

// Gruplanmış sırayla düz liste (Excel satır sırası da bu olur)
function grupluSirala(kalemler, indexFn) {
  return grupla(kalemler, indexFn).flatMap(([, list]) => list);
}
