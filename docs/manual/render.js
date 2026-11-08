const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch({ args: ['--no-sandbox','--disable-dev-shm-usage','--no-proxy-server'] });
  for (const [src, out, title] of [
    ['admin.html',  'Kubo Ca Phe - Owner Manual.pdf',  'Owner'],
    ['barista.html','Kubo Ca Phe - Barista Guide.pdf', 'Barista'],
  ]) {
    const p = await b.newPage();
    await p.goto('file:///tmp/manual/' + src, { waitUntil: 'networkidle' });
    await p.evaluate(() => document.fonts.ready);
    await p.waitForTimeout(500);
    await p.pdf({
      path: '/tmp/manual/' + out,
      format: 'A4',
      printBackground: true,
      displayHeaderFooter: true,
      headerTemplate: '<div></div>',
      footerTemplate: `<div style="width:100%;font-size:7pt;color:#8B8C91;
        font-family:sans-serif;padding:0 16mm;display:flex;
        justify-content:space-between;">
        <span>Kubo Cà Phê · ${title}</span>
        <span class="pageNumber"></span></div>`,
      margin: { top: '17mm', bottom: '16mm', left: '16mm', right: '16mm' },
    });
    await p.close();
    console.log('wrote', out);
  }
  await b.close();
})();
