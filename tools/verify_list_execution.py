#!/usr/bin/env python3
"""Reproduce v5 list/exists execution on pinned copies; retain all unknown stops."""
if __package__:
    from .verify_table_execution import main
else:
    from verify_table_execution import main


if __name__=='__main__':
    choices=[]
    for pack in ['data7','data8']:
        selected=[f'{pack}.pack/misc/value.s',f'{pack}.pack/avg/setting.txt',f'{pack}.pack/avg/projectsetting.txt',
            f'{pack}.pack/script/config/value.s']
        choices.append((f'explicit_{pack}_config_module',selected))
        choices.append((f'explicit_{pack}_list_file',selected+[f'{pack}.pack/script/config/valuedefault.txt']))
    raise SystemExit(main(stage='round28',report_name='list-execution-report.json',profile='experimental_static_contracts_v5',
        extra_evidence=['index-native-report','index-allocation-native-report','index-binding-report',
            'list-native-report','list-helper-native-report','list-path-native-report','list-binding-report'],extra_choices=choices))
