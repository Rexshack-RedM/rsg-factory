(() => {
    const app = document.getElementById('app');
    const view = document.getElementById('view');
    const titleEl = document.getElementById('title');
    const subEl = document.getElementById('subtitle');
    const modal = document.getElementById('modal');

    let S = {};
    let state = null;
    let items = [];
    let mode = 'player';
    let draft = null;
    let tick = null;

    const post = (name, data = {}) =>
        fetch(`https://${GetParentResourceName()}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data),
        }).then(r => r.json()).catch(() => null);

    const h = (tag, cls, text) => {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (text !== undefined) e.textContent = text;
        return e;
    };

    const divider = (text) => {
        const d = h('div', 'divider');
        d.append(h('span', 'star', '✦'), h('span', '', text), h('span', 'star', '✦'));
        return d;
    };

    const fmt = (s) => {
        const m = Math.floor(s / 60), sec = s % 60;
        return `${m}:${String(sec).padStart(2, '0')}`;
    };

    const listText = (list) => list.map(e => `${e.amount}x ${e.label}`).join(', ');

    /* ---------- close / modal ---------- */
    const closeUi = () => post('close');

    const confirmModal = (text, onOk) => {
        document.getElementById('modalTitle').textContent = S.ui_delete;
        document.getElementById('modalText').textContent = text;
        const ok = document.getElementById('modalOk');
        const cancel = document.getElementById('modalCancel');
        ok.textContent = S.ui_confirm;
        cancel.textContent = S.ui_cancel;
        modal.classList.remove('hidden');
        cancel.onclick = () => modal.classList.add('hidden');
        ok.onclick = () => { modal.classList.add('hidden'); onOk(); };
    };

    /* ---------- player view ---------- */
    const updateTimers = () => {
        let anyReady = false;
        document.querySelectorAll('[data-finish]').forEach(el => {
            const left = Math.max(0, Math.ceil((Number(el.dataset.finish) - Date.now()) / 1000));
            if (left === 0) {
                el.textContent = S.ui_ready;
                el.classList.add('ok');
                anyReady = true;
            } else {
                el.textContent = fmt(left);
            }
        });
        document.querySelectorAll('.stage-line').forEach(el => {
            const st = el._stages || [];
            const now = Date.now();
            const i = st.findIndex(x => x.endsAt > now);
            el.textContent = i === -1 ? '' : `${S.ui_stage} ${i + 1}/${st.length}: ${st[i].label}`;
        });
        const btn = document.getElementById('collectBtn');
        if (btn) btn.disabled = !anyReady;
    };

    const refresh = async () => {
        const data = await post('refresh');
        if (data && data.id) { state = data; render(); }
    };

    const renderPlayer = () => {
        titleEl.textContent = state.name;
        subEl.textContent = S.ui_recipes;

        view.append(divider(S.ui_queue));
        if (!state.queue.length) {
            view.append(h('div', 'empty', S.ui_no_queue));
        } else {
            state.queue.forEach(q => {
                const row = h('div', 'row');
                const g = h('div', 'grow');
                g.append(h('div', 'name', q.label), h('div', 'desc', listText(q.outputs)));
                if (q.stages && q.stages.length > 1) {
                    const sl = h('div', 'desc stage-line');
                    sl._stages = q.stages.map(x => ({ label: x.label, endsAt: Date.now() + x.endsIn * 1000 }));
                    g.append(sl);
                }
                const b = h('span', 'badge');
                b.dataset.finish = String(Date.now() + q.remaining * 1000);
                row.append(g, b);
                view.append(row);
            });
            const actions = h('div', 'actions');
            const collect = h('button', 'wood-btn', S.ui_collect);
            collect.id = 'collectBtn';
            collect.disabled = true;
            collect.onclick = async () => { await post('collect'); refresh(); };
            actions.append(collect);
            view.append(actions);
        }

        view.append(divider(S.ui_recipes));
        if (!state.recipes.length) view.append(h('div', 'empty', S.ui_no_recipes));

        state.recipes.forEach((r, i) => {
            const row = h('div', 'row');
            const g = h('div', 'grow');
            const d = h('div', 'desc');
            const mk = (label, val) => {
                const s = h('div', '');
                s.append(document.createTextNode(label + ': '), h('b', '', val));
                return s;
            };
            d.append(
                mk(S.ui_inputs, listText(r.inputs)),
                mk(S.ui_outputs, listText(r.outputs)),
                mk(S.ui_time, `${r.time}${S.ui_seconds_short}`),
            );
            const chain = [];
            let cur = r.next, guard = 0;
            while (cur > 0 && state.recipes[cur - 1] && guard++ < 10) {
                chain.push(state.recipes[cur - 1].label);
                cur = state.recipes[cur - 1].next;
            }
            if (chain.length) d.append(mk(S.ui_next_line, chain.join(' → ')));
            g.append(h('div', 'name', r.label), d);
            if (r.job) g.append(h('span', 'badge', r.job));

            const p = h('div', 'produce');
            const qty = h('input');
            qty.type = 'number'; qty.min = '1'; qty.max = String(state.maxBatches); qty.value = '1';
            qty.title = S.ui_batches;
            const btn = h('button', 'wood-btn', S.ui_produce);
            btn.onclick = async () => {
                const n = Math.max(1, Math.min(state.maxBatches, parseInt(qty.value, 10) || 1));
                btn.disabled = true;
                await post('start', { recipe: i + 1, batches: n });
                btn.disabled = false;
                refresh();
            };
            p.append(qty, btn);
            row.append(g, p);
            view.append(row);
        });

        updateTimers();
    };

    /* ---------- custom item dropdown ---------- */
    const itemDropdown = (entry) => {
        const dd = h('div', 'dd');
        const inp = h('input', 'dd-input');
        inp.type = 'text';
        inp.placeholder = S.ui_search_item;
        const arrow = h('span', 'dd-arrow', '▾');
        const menu = h('div', 'dd-menu');
        dd.append(inp, arrow, menu);

        const labelOf = (name) => (items.find(i => i.name === name) || {}).label || name || '';
        inp.value = labelOf(entry.item);

        const fill = (q) => {
            menu.innerHTML = '';
            q = (q || '').toLowerCase();
            let n = 0;
            for (const it of items) {
                if (q && !it.label.toLowerCase().includes(q) && !it.name.toLowerCase().includes(q)) continue;
                const o = h('div', 'dd-opt' + (it.name === entry.item ? ' sel' : ''), it.label);
                o.title = it.name;
                o.addEventListener('mousedown', (e) => {
                    e.preventDefault();
                    entry.item = it.name;
                    inp.value = it.label;
                    dd.classList.remove('open');
                });
                menu.append(o);
                if (++n >= 60) break;
            }
        };

        inp.addEventListener('focus', () => { inp.select(); fill(''); dd.classList.add('open'); });
        inp.addEventListener('input', () => { fill(inp.value); dd.classList.add('open'); });
        inp.addEventListener('blur', () => { dd.classList.remove('open'); inp.value = labelOf(entry.item); });
        return dd;
    };

    /* ---------- simple custom dropdown (no native select) ---------- */
    const simpleDropdown = (options, value, onChange) => {
        const dd = h('div', 'dd');
        const inp = h('input', 'dd-input');
        inp.type = 'text';
        inp.readOnly = true;
        const arrow = h('span', 'dd-arrow', '▾');
        const menu = h('div', 'dd-menu');
        dd.append(inp, arrow, menu);
        const labelOf = (v) => (options.find(o => o.value === v) || options[0]).label;
        inp.value = labelOf(value);
        options.forEach(o => {
            const el = h('div', 'dd-opt' + (o.value === value ? ' sel' : ''), o.label);
            el.addEventListener('mousedown', (e) => {
                e.preventDefault();
                value = o.value;
                inp.value = o.label;
                menu.querySelectorAll('.dd-opt').forEach(x => x.classList.remove('sel'));
                el.classList.add('sel');
                dd.classList.remove('open');
                inp.blur();
                onChange(o.value);
            });
            menu.append(el);
        });
        inp.addEventListener('focus', () => dd.classList.add('open'));
        inp.addEventListener('blur', () => dd.classList.remove('open'));
        return dd;
    };

    /* ---------- admin view ---------- */
    const itemList = (list) => {
        const wrap = h('div');
        const redraw = () => {
            wrap.innerHTML = '';
            list.forEach((entry, idx) => {
                const row = h('div', 'item-row');
                const amt = h('input');
                amt.type = 'number'; amt.min = '1'; amt.max = String(state.limits.amount);
                amt.placeholder = S.ui_amount;
                amt.value = entry.amount;
                amt.oninput = () => { entry.amount = parseInt(amt.value, 10) || 0; };
                const rm = h('button', 'mini-btn', '✕');
                rm.title = S.ui_remove;
                rm.onclick = () => { list.splice(idx, 1); redraw(); };
                row.append(itemDropdown(entry), amt, rm);
                wrap.append(row);
            });
            if (list.length < state.limits.items) {
                const add = h('button', 'wood-btn muted link-btn', '+ ' + S.ui_add_item);
                add.onclick = () => { list.push({ item: '', amount: 1 }); redraw(); };
                wrap.append(add);
            }
        };
        redraw();
        return wrap;
    };

    const textField = (label, value, onInput, max) => {
        const f = h('div', 'field');
        f.append(h('label', '', label));
        const i = h('input');
        i.type = 'text'; i.value = value || ''; i.maxLength = max || 64;
        i.oninput = () => onInput(i.value);
        f.append(i);
        return f;
    };

    const renderAdmin = () => {
        titleEl.textContent = S.ui_admin_title;
        subEl.textContent = state.name;

        const top = h('div', 'grid2');
        top.append(
            textField(S.ui_factory_name, draft.name, v => { draft.name = v; }, 64),
            textField(S.ui_ped_model, draft.ped_model, v => { draft.ped_model = v; }, 64),
        );
        view.append(top, divider(S.ui_recipes));

        draft.recipes.forEach((r, idx) => {
            const card = h('div', 'card');
            const head = h('div', 'card-head');
            const rm = h('button', 'mini-btn', '✕');
            rm.title = S.ui_remove;
            rm.onclick = () => {
                draft.recipes.splice(idx, 1);
                draft.recipes.forEach(x => {
                    if (x.next === idx + 1) x.next = 0;
                    else if (x.next > idx + 1) x.next -= 1;
                });
                render();
            };
            head.append(rm);

            const grid = h('div', 'grid3');
            const time = textField(S.ui_seconds, String(r.time), v => { r.time = parseInt(v, 10) || 0; }, 5);
            grid.append(
                textField(S.ui_recipe_name, r.label, v => { r.label = v; }, 48),
                time,
                textField(S.ui_job_lock, r.job || '', v => { r.job = v; }, 32),
            );

            const nextOptions = [{ value: 0, label: S.ui_no_next }];
            draft.recipes.forEach((x, j) => {
                if (j !== idx) nextOptions.push({ value: j + 1, label: x.label || `#${j + 1}` });
            });
            const nextField = h('div', 'field');
            nextField.append(h('label', '', S.ui_next_line), simpleDropdown(nextOptions, r.next || 0, v => { r.next = v; }));

            card.append(head, grid,
                h('div', 'sub-title', S.ui_inputs), itemList(r.inputs),
                h('div', 'sub-title', S.ui_outputs), itemList(r.outputs),
                h('div', 'sub-title', ''), nextField);
            view.append(card);
        });

        if (draft.recipes.length < state.limits.recipes) {
            const add = h('button', 'wood-btn muted', '+ ' + S.ui_add_recipe);
            add.onclick = () => {
                draft.recipes.push({
                    label: '', time: 30, job: '', next: 0,
                    inputs: [{ item: '', amount: 1 }], outputs: [{ item: '', amount: 1 }],
                });
                render();
            };
            view.append(add);
        }

        const actions = h('div', 'actions');
        const del = h('button', 'wood-btn danger muted', S.ui_delete);
        del.onclick = () => confirmModal(S.ui_confirm_delete, async () => {
            const ok = await post('delete');
            if (ok) closeUi();
        });
        const save = h('button', 'wood-btn', S.ui_save);
        save.onclick = async () => {
            save.disabled = true;
            const ok = await post('save', draft);
            save.disabled = false;
            if (ok) closeUi();
        };
        actions.append(del, save);
        view.append(actions);
    };

    /* ---------- render ---------- */
    function render() {
        const scroll = view.scrollTop;
        view.innerHTML = '';
        if (mode === 'admin') renderAdmin(); else renderPlayer();
        view.scrollTop = scroll;
    }

    window.addEventListener('message', (ev) => {
        const d = ev.data;
        if (!d || !d.action) return;

        if (d.action === 'open') {
            S = d.strings || {};
            mode = d.mode;
            state = d.factory;
            items = d.items || [];
            document.getElementById('closeBtn').title = S.ui_close || 'Close';
            if (mode === 'admin') {
                draft = {
                    name: state.name,
                    ped_model: state.ped_model,
                    recipes: state.recipes.map(r => ({
                        label: r.label, time: r.time, job: r.job || '', next: r.next || 0,
                        inputs: r.inputs.map(e => ({ item: e.item, amount: e.amount })),
                        outputs: r.outputs.map(e => ({ item: e.item, amount: e.amount })),
                    })),
                };
            }
            modal.classList.add('hidden');
            app.classList.remove('hidden');
            render();
            clearInterval(tick);
            tick = setInterval(updateTimers, 1000);
        } else if (d.action === 'close') {
            app.classList.add('hidden');
            modal.classList.add('hidden');
            clearInterval(tick);
            view.innerHTML = '';
        }
    });

    document.getElementById('closeBtn').addEventListener('click', closeUi);
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') closeUi();
    });
})();
