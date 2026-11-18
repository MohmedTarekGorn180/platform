/* AQDAR shared identity bar + role-specific linking tools */
(() => {
  'use strict';
  const labels = { student: 'طالب', parent: 'ولي أمر', teacher: 'معلم', admin: 'إدارة' };
  const icons = { student: '🎓', parent: '👨‍👩‍👧', teacher: '👨‍🏫', admin: '🛡️' };
  function getClient() {
    if (window.supabaseClient) return window.supabaseClient;
    if (window.sb) return window.sb;
    try {
      if (window.supabase?.createClient) {
        const url = (typeof SUPABASE_URL !== 'undefined' ? SUPABASE_URL : 'https://khjqgpbyyexbgakvajhj.supabase.co');
        const key = (typeof SUPABASE_ANON_KEY !== 'undefined' ? SUPABASE_ANON_KEY : 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtoanFncGJ5eWV4Ymdha3ZhamhqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI1ODczMTEsImV4cCI6MjEwODE2MzMxMX0.7kd44Ye1dyZZnVq8bcCVj0t1DWhAnkLkhpYA5Ndln6U');
        return window.supabase.createClient(url, key);
      }
    } catch (_) {}
    return null;
  }
  function addStyles() {
    if (document.getElementById('aqdar-role-style')) return;
    const s = document.createElement('style'); s.id = 'aqdar-role-style';
    s.textContent = `
      #aqdar-role-bar{position:sticky;top:0;z-index:9998;display:flex;align-items:center;justify-content:space-between;gap:12px;padding:9px 18px;background:linear-gradient(110deg,#0b2b6b,#1248b8 62%,#0e7490);color:#fff;box-shadow:0 5px 18px #0b2b6b22;font:700 13px/1.5 Cairo,Tahoma,sans-serif}
      #aqdar-role-bar .aqrb-main{display:flex;align-items:center;gap:9px;min-width:0}#aqdar-role-bar .aqrb-icon{width:30px;height:30px;display:grid;place-items:center;border-radius:10px;background:#ffffff20;font-size:17px}
      #aqdar-role-bar .aqrb-sub{font-size:11px;opacity:.78;font-weight:500}#aqdar-role-bar .aqrb-role{padding:4px 11px;border:1px solid #ffffff55;border-radius:999px;white-space:nowrap;background:#ffffff17}
      #aqdar-role-tools{position:fixed;bottom:18px;inset-inline-end:18px;z-index:9997;display:grid;gap:8px;width:min(360px,calc(100vw - 36px));font:13px/1.6 Cairo,Tahoma,sans-serif}
      .aqrb-card{background:#fff;color:#10244b;border:1px solid #dbe5f5;border-radius:16px;padding:14px;box-shadow:0 12px 36px #10244b26}
      .aqrb-card h3{margin:0 0 8px;font-size:15px}.aqrb-card p{margin:5px 0;color:#536783}.aqrb-code{font-size:20px;font-weight:900;letter-spacing:1px;color:#1248b8;background:#eff5ff;padding:8px;border-radius:9px;text-align:center;direction:ltr}
      .aqrb-actions{display:flex;gap:7px;flex-wrap:wrap;margin-top:9px}.aqrb-btn{border:0;border-radius:9px;padding:8px 12px;background:#1248b8;color:white;font:700 12px Cairo;cursor:pointer}.aqrb-btn.alt{background:#edf2fa;color:#19345f}.aqrb-input{width:100%;padding:10px;border:1px solid #cbd8ed;border-radius:9px;font:13px Cairo;direction:ltr;box-sizing:border-box}
      .aqrb-list{max-height:230px;overflow:auto}.aqrb-item{padding:9px 0;border-bottom:1px solid #e8edf5}.aqrb-close{float:left;background:none;border:0;font-size:18px;cursor:pointer;color:#64748b}
      @media(max-width:600px){#aqdar-role-bar{padding:8px 12px}#aqdar-role-tools{bottom:10px;inset-inline-end:10px}}
    `; document.head.appendChild(s);
  }
  function panel(title, body) {
    let wrap = document.getElementById('aqdar-role-tools');
    if (!wrap) { wrap = document.createElement('div'); wrap.id = 'aqdar-role-tools'; document.body.appendChild(wrap); }
    const card = document.createElement('section'); card.className = 'aqrb-card';
    card.innerHTML = '<button class="aqrb-close" aria-label="إغلاق">×</button><h3></h3><div class="aqrb-body"></div>';
    card.querySelector('h3').textContent = title; card.querySelector('.aqrb-body').append(body);
    card.querySelector('.aqrb-close').onclick = () => card.remove(); wrap.append(card); return card;
  }
  function button(label, action, alt=false) {
    const b=document.createElement('button'); b.className='aqrb-btn'+(alt?' alt':''); b.textContent=label; b.onclick=action; return b;
  }
  async function start() {
    const sb=getClient(); if(!sb) return;
    const {data:{user}}=await sb.auth.getUser(); if(!user) return;
    const {data:p,error}=await sb.from('profiles').select('role,display_name,first_name,last_name,username').eq('id',user.id).maybeSingle();
    if(error||!p?.role) return;
    const role=String(p.role).toLowerCase(); if(!labels[role]) return;
    addStyles();
    const bar=document.createElement('div');bar.id='aqdar-role-bar';
    const name=p.display_name||[p.first_name,p.last_name].filter(Boolean).join(' ')||p.username||'مستخدم';
    const main=document.createElement('div');main.className='aqrb-main';
    const ico=document.createElement('span');ico.className='aqrb-icon';ico.textContent=icons[role];
    const copy=document.createElement('div');copy.textContent='أنت تستخدم منصة أقدر بصفتك: '+labels[role];
    const sub=document.createElement('div');sub.className='aqrb-sub';sub.textContent=name;copy.append(sub);main.append(ico,copy);
    const badge=document.createElement('span');badge.className='aqrb-role';badge.textContent=labels[role];bar.append(main,badge);
    document.body.insertBefore(bar,document.body.firstChild);
    const logout=button('تسجيل الخروج',async()=>{await sb.auth.signOut();location.replace('login.html');},true);
    const logoutBody=document.createElement('div');logoutBody.append(logout);panel('الحساب',logoutBody);
    if(role==='student'){
      const body=document.createElement('div');
      const p1=document.createElement('p');p1.textContent='أنشئ كودًا لمرة واحدة وشاركه مع ولي أمرك. الكود صالح لمدة 30 يومًا ويُستخدم لربط حساب ولي الأمر.';
      const codeEl=document.createElement('div');codeEl.className='aqrb-code';codeEl.textContent='لم يتم إنشاء كود بعد';
      const actions=document.createElement('div');actions.className='aqrb-actions';
      const generate=button('إنشاء كود ولي الأمر',async()=>{
        generate.disabled=true;generate.textContent='جاري الإنشاء...';
        const {data:code,error:e}=await sb.rpc('aqdar_get_my_student_code');
        generate.disabled=false;generate.textContent='إنشاء كود جديد';
        if(e){alert('تعذر إنشاء الكود. تأكد من تطبيق تحديث قاعدة البيانات.');return;}
        codeEl.textContent=code;
        const copy=button('نسخ الكود',()=>navigator.clipboard?.writeText(code).then(()=>alert('تم نسخ الكود')).catch(()=>alert('الكود: '+code)),true);
        actions.querySelector('[data-copy]')?.remove();copy.dataset.copy='1';actions.append(copy);
      });
      actions.append(generate);body.append(p1,codeEl,actions);panel('كود ربط ولي الأمر',body);
    }
    if(role==='parent' && !location.pathname.endsWith('parent-login.html')){
      const body=document.createElement('div');
      const p1=document.createElement('p');p1.textContent='أدخل الكود الذي حصلت عليه من الطالب. سيتم ربط الحسابين مباشرة، وستتمكن من مشاهدة بيانات الطالب فقط.';
      const input=document.createElement('input');input.className='aqrb-input';input.placeholder='AQD-XXXXXXXXXXXX';input.maxLength=20;input.autocomplete='off';
      const actions=document.createElement('div');actions.className='aqrb-actions';
      const send=button('ربط الطالب',async()=>{
        send.disabled=true;
        const {error:e}=await sb.rpc('aqdar_redeem_student_code',{p_code:input.value.trim()});
        send.disabled=false;
        if(e){alert(e.message||'الكود غير صحيح أو مستخدم.');return;}
        alert('تم ربط الطالب بحسابك بنجاح. يمكنك الآن متابعة إحصائياته.');
        input.value='';
        if(location.pathname.endsWith('parent-login.html')) location.reload();
      });
      actions.append(send);body.append(p1,input,actions);panel('ربط حساب الطالب',body);
    }

  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>start().catch(console.error));else start().catch(console.error);
})();