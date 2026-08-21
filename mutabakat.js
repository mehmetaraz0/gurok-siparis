// mutabakat.js — LN entegrasyonu saf mantık (tarayıcı + Node/vm ile test edilir)

// LN sayı biçimi: tam sayı "5.0", ondalık "2.5" (eskiden "2.5.0" üretip XML'i bozuyordu)
function tdpurMiktar(v) {
  const n = Number(v);
  return Number.isInteger(n) ? n + ".0" : String(n);
}

// LN tdpur (depo talep) çıktısı — SABİT ŞABLON.
// 1. satır (başlık) ve 2. satırdaki tüm sabit alanlar (talep eden, depo, tarih, vb.)
// olduğu gibi korunur; her ürün için 2. satır kopyalanıp YALNIZCA şu kolonlar değişir:
//   T = Pozisyon/sıra (10, 20, 30 ...)   V = kalem kodu
//   W = kalem tanımı                     X = sipariş miktarı      Y = birim
//   kalemler: [{k, a, b, m}]
async function buildDepoSiparisBlob(kalemler) {
  const tplBytes = Uint8Array.from(atob(TPL_DEPO_B64), c => c.charCodeAt(0));
  const zip = await JSZip.loadAsync(tplBytes);
  let sheet = await zip.file("xl/worksheets/sheet1.xml").async("string");

  // Şablondaki örnek satırı çıkar (yerine gerçek kalemler yazılacak)
  sheet = sheet.replace(/<row r="2">[\s\S]*?<\/row>/, "");

  let newRows = "";
  for (let i = 0; i < kalemler.length; i++) {
    const it = kalemler[i];
    const rn = i + 2;

    let row = ROW2_DEPO.replace(/r="2"/g, 'r="' + rn + '"');
    row = row.replace(/r="([A-Z]{1,2})2"/g, 'r="$1' + rn + '"');

    const hucre = (sut, icerik) => {
      row = row.replace(new RegExp('<c r="' + sut + rn + '"[^>]*>.*?</c>'), icerik);
    };

    hucre("T", '<c r="T' + rn + '" t="n" s="15"><v>' + ((i + 1) * 10) + '</v></c>');
    hucre("V", '<c r="V' + rn + '" t="inlineStr"><is><t>' + xmlEsc(it.k) + '</t></is></c>');
    hucre("W", '<c r="W' + rn + '" t="inlineStr"><is><t>' + xmlEsc(it.a) + '</t></is></c>');
    hucre("X", '<c r="X' + rn + '" t="n"><v>' + tdpurMiktar(it.m) + '</v></c>');
    hucre("Y", '<c r="Y' + rn + '" t="inlineStr"><is><t>' + xmlEsc(it.b) + '</t></is></c>');

    newRows += row + "\n";
  }

  sheet = sheet.replace("</sheetData>", newRows + "</sheetData>");
  zip.file("xl/worksheets/sheet1.xml", sheet);

  return await zip.generateAsync({
    type: "blob",
    mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  });
}

// Bir outlet'in onaylı siparişlerini kod bazında toplar (outlet çıkış Excel'i için).
// Dönüş buildExcelBlob'un beklediği [{k,a,b,m}] biçiminde, kod'a göre sıralı.
//   siparisler: depo_envanter dönüşü [{outlet_kod, durum, kalemler:[{k,a,b,m,o?}]}]
//   Sadece durum='onaylandi' ve outlet_kod===outletKod; miktar = o ?? m; m>0 süzülür.
function haftalikCikisTopla(siparisler, outletKod) {
  var map = {};
  (siparisler || []).forEach(function (s) {
    if (s.durum !== "onaylandi" || s.outlet_kod !== outletKod) return;
    (s.kalemler || []).forEach(function (el) {
      var mik = (el.o === undefined || el.o === null) ? Number(el.m) : Number(el.o);
      if (!(mik > 0)) return;
      if (!map[el.k]) map[el.k] = { k: el.k, a: el.a, b: el.b || "ad", m: 0 };
      map[el.k].m += mik;
    });
  });
  return Object.keys(map).sort().map(function (k) { return map[k]; });
}
