import sudo

SEMAP = {
  "user=auditor": ['selinux_role=unconfined_r', 'selinux_type=auditor.process']
}


class ApprovalPlugin(sudo.Plugin):
    def check(self, command_info: tuple, run_argv: tuple,
              run_env: tuple) -> int:
        for i in self.user_info:
            if i.startswith("user="):
                res = SEMAP.get(i, None)
                if res:
                    if not set(command_info).issuperset(set(res)):
                         sudo.log_info("incorrect selinux type or role, expecting " + str(res) )
                         raise sudo.PluginReject("incorrect selinux type or role")
                break
