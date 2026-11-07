"""Bounded hypothesis for one UTF-16 integer helper, not a script evaluator.

Derived from static observations at 0x404ffc, not original-code execution.
The caller at 0x69af88 has a narrower first-character gate. Embedded NUL and
overlong inputs stay outside this probe's scope. Failed conversions have no
invented numeric result. This does not model strings, variables or arithmetic.
"""

MAX_CHARACTERS=8192
MASK32=0xffffffff


def caller_numeric_gate(text):
    """Observed raw first-character gate; it does not imply parse success."""
    return bool(text) and (text[0] in '$+-' or '0'<=text[0]<='9')


def probe(text):
    if not isinstance(text,str):raise TypeError('literal_must_be_text')
    result=dict(status='inferred',scope='Static model of helper 0x404ffc only',
        original_execution_equivalence='not_tested',caller_gate=caller_numeric_gate(text))
    if len(text)>MAX_CHARACTERS or '\0' in text:
        result.update(status='not_tested',accepted=None,unknown_reason=(
            'literal_character_limit' if len(text)>MAX_CHARACTERS else 'embedded_NUL_outside_probe_scope'))
        return result
    i=0
    while i<len(text) and text[i]==' ':i+=1
    negative=i<len(text) and text[i]=='-'
    if i<len(text) and text[i] in '+-':i+=1
    base=10
    if text[i:i+1] in {'$','x','X'}:base=16;i+=1
    elif text[i:i+2] in {'0x','0X'}:base=16;i+=2
    result['base']=base
    def reject(reason):
        return dict(result,accepted=False,rejection_reason=reason)
    if i==len(text):return reject('missing_digits')
    value=0
    for c in text[i:]:
        if '0'<=c<='9':digit=ord(c)-ord('0')
        elif base==16 and 'a'<=c<='f':digit=ord(c)-ord('a')+10
        elif base==16 and 'A'<=c<='F':digit=ord(c)-ord('A')+10
        else:return reject('invalid_digit_or_trailing_character')
        if value>(0x0fffffff if base==16 else 0x0ccccccc):return reject('accumulation_bound')
        value=value*base+digit
    if base==10 and value>(0x80000000 if negative else 0x7fffffff):return reject('decimal_signed_range')
    bits=(-value if negative else value)&MASK32
    return dict(result,accepted=True,bits_u32=bits,signed_i32=bits if bits<0x80000000 else bits-0x100000000)
