//! 后台「站点设置」页的客户端校验（等价 C# 页面的内联脚本）。
//!
//! 为什么放静态文件：zzig 的 Razor 子集在 `@section` 体内遇到 `}` 即结束块，
//! 内联 `<script>` 里的函数体花括号会被误判为块结束；外链脚本没有这个问题。
//!
//! 为什么不用 `window.alert`：全局「面板前端交互规范」禁止原生弹窗——
//! 这里改为就地提示（错误文案写进 `#SiteNameTip`，焦点回到输入框）。

(function () {
    var form = document.querySelector('.admin-form');
    if (!form) {
        return;
    }
    form.addEventListener('submit', function (event) {
        var input = document.getElementById('SiteName');
        if (!input) {
            return;
        }
        var value = (input.value || '').replace(/^\s+|\s+$/g, '');
        if (value.length > 0) {
            var tip = document.getElementById('SiteNameTip');
            if (tip) {
                tip.textContent = '';
                tip.style.display = 'none';
            }
            return;
        }
        event.preventDefault();
        var tip = document.getElementById('SiteNameTip');
        if (tip) {
            tip.textContent = '网站名称不可为空';
            tip.style.display = 'block';
        }
        input.focus();
    });
})();
