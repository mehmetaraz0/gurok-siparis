-- GUROK: cay ocaklari app'e bar olarak eklenir (siparis_gonder icin gecerli outlet).
insert into public.outletler (kod, ad, tur) values
  ('CSM401','RESEPSIYON CAY OCAGI','bar'),
  ('CSM402','PARK RESEPSIYON CAY OCAGI','bar'),
  ('CSM403','IDARI BINA CAY OCAGI','bar')
on conflict (kod) do nothing;
