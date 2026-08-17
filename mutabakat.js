// mutabakat.js — LN entegrasyonu saf mantık (tarayıcı + Node/vm ile test edilir)

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
