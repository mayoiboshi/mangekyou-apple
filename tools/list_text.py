"""Independent bounded string-list morphology model; no game execution."""
import re
if __package__:
    from .qlie_lex import codec_for, decode_spans, digest
    from .mangekyou_p0 import ProbeError, safe_member_name
else:
    from qlie_lex import codec_for, decode_spans, digest
    from mangekyou_p0 import ProbeError, safe_member_name


def string_list_text(data, source):
    source=safe_member_name(source)
    if len(data)>1024*1024: raise ProbeError('list_source_size_limit')
    codec,bom,_=codec_for(data);text,spans=decode_spans(data[bom:],codec,bom)
    if any(ord(c)<32 and c not in '\t\r\n' for c in text): raise ProbeError('list_control_bytes')
    identity=digest(data)
    def ref(a,b,n):return dict(sourceFile=source,sourceSHA256=identity,byteOffset=a,byteLength=b-a,rangeSHA256=digest(data[a:b]),lineNumber=n)
    lines=[];names=set()
    for match in re.finditer(r'[^\r\n]*(?:\r\n|\r|\n|$)',text):
        if match.start()==match.end():continue
        if len(lines)>=10000: raise ProbeError('list_line_limit')
        full=match.group();body=full[:-2] if full.endswith('\r\n') else full[:-1] if full.endswith(('\r','\n')) else full
        if len(body.encode('utf-8'))>8192: raise ProbeError('list_line_length_limit')
        a=spans[match.start()][0];b=spans[match.end()-1][1]
        row=dict(location=ref(a,b,len(lines)+1),textSHA256=digest(body.encode('utf-8')),comparisonStatus='not_tested')
        name,separator,value=body.partition('=')
        if separator:
            if name.isascii():names.add(name.lower())
            row.update(nameSHA256=digest(name.encode('utf-8')),valueSHA256=digest(value.encode('utf-8')),
                comparisonStatus='inferred' if name.isascii() else 'unsupported')
        lines.append(row)
    return dict(status='inferred',source=ref(0,len(data),1),lineCount=len(lines),nameCount=len(names),
        unresolvedNameCount=sum(r['comparisonStatus']=='unsupported' for r in lines),lines=lines)
