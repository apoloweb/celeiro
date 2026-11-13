/* Área do cliente: ligação com o Celeiro Office.
   O endereço e a chave pública do banco do SITE vêm de ../config.js.
   Aqui ficam o endereço e a chave PÚBLICA do Office, usados só para registrar leads e solicitações
   (função app_registrar) e ler quais módulos estão ligados (função app_config).
   NUNCA coloque aqui uma chave secret / service_role. */
window.CELEIRO_CLIENTE = {
  officeUrl: "https://wvvounloqtucagerizct.supabase.co",
  officeKey: "sb_publishable_ZSW04enHBahN-I8wfpkJfw_4z-HBuG3",
  teste: false   // true = o que for enviado ao Office chega marcado como teste e fica fora dos totais
};
