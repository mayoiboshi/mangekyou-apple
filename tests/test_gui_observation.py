"""Owned metadata verifies comparison only, not the occurrence of a UI replay."""
import copy
import unittest
from tools.verify_gui_observation import match_final
from tools.mangekyou_p0 import ProbeError


class GuiObservationTests(unittest.TestCase):
    def test_final_state_must_match_all_checked_cli_fields(self):
        final=dict(steps=3,callDepth=1,moduleSnapshotCount=1,tableObjectCount=0,tableEntryCount=0,listObjectCount=1,listLineCount=2,
            sourceFile='owned.s',lineNumber=4,byteOffset=20,command='unknown',stopReason='unsupported_command')
        machine={k:v for k,v in final.items() if k not in {'sourceFile','lineNumber','byteOffset','command'}}
        machine.update(currentLocation={k:final[k] for k in ['sourceFile','lineNumber','byteOffset']},trace=[dict(command='unknown')])
        self.assertEqual(match_final(final,dict(machine=machine)),final)
        for key in final:
            forged=copy.deepcopy(final);forged[key]='wrong'
            with self.assertRaises(ProbeError):match_final(forged,dict(machine=machine))
        with self.assertRaises(ProbeError):match_final(dict(final,decoded_text='forbidden'),dict(machine=machine))
        with self.assertRaises(ProbeError):match_final(dict(final,callDepth=True),dict(machine=machine))
