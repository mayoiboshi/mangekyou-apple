#!/usr/bin/env python3
"""Reproduce v4 array execution on pinned research copies, retaining all unsupported stops."""
if __package__:
    from .verify_table_execution import main
else:
    from verify_table_execution import main


if __name__ == '__main__':
    choices = [(f'explicit_{pack}_config_module',[
        f'{pack}.pack/misc/value.s', f'{pack}.pack/avg/setting.txt',
        f'{pack}.pack/avg/projectsetting.txt', f'{pack}.pack/script/config/value.s']) for pack in ['data7','data8']]
    raise SystemExit(main(stage='round27', report_name='index-execution-report.json', profile='experimental_static_contracts_v4',
        extra_evidence=['index-native-report','index-allocation-native-report','index-binding-report'],extra_choices=choices))
