-- helpers.lua — helpers compartilhados dos testes (plan: terrabrasilis-integration, Inc 2)
--
-- days_ago(n): data "YYYY-MM-DD" n dias atrás, em UTC. As fixtures dos testes
-- passam a ser relativas ao relógio (nada de datas absolutas que viram
-- date-bombs quando a janela de 90d do DETER avança).
-- fake_ctx(): fake request context, idêntico às cópias locais dos testes
-- (as outras cópias ficam nos arquivos por ora; Inc posterior as deduplica).

function _G.days_ago(n)
    return os.date("!%Y-%m-%d", os.time() - n * 86400)
end

function _G.fake_ctx(args)
    return {
        req = { args = args or {}, remote_addr = "127.0.0.1", headers = {} },
        status = nil, body = nil, content_type = nil, headers = {},
        json = function(self, status, data) self.status = status; self.body = data end,
        error = function(self, status, msg) self.status = status; self.body = { error = msg } end,
        send = function(self, status, body, ct) self.status = status; self.body = body; self.content_type = ct end,
        set_header = function(self, k, v) self.headers[k] = v end,
    }
end
