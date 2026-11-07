"""Lossless lexical facts only. Does not evaluate any QLIE instruction."""
import codecs
import hashlib
import re

try:
    from .mangekyou_p0 import ProbeError
except ImportError:
    from mangekyou_p0 import ProbeError

MAX_TEXT = 16 * 1024 * 1024
MAX_LINES = 100_000
MAX_TOKENS = 200_000
MAX_FIELDS = 4096


def digest(data):
    return hashlib.sha256(data).hexdigest()


def codec_for(data):
    for marker, codec in [(b'\xff\xfe','utf-16-le'),(b'\xfe\xff','utf-16-be'),(b'\xef\xbb\xbf','utf-8')]:
        if data.startswith(marker):return codec,len(marker),'verified'
    return 'cp932',0,'inferred'


def decode_spans(raw, codec, base=0):
    """Exact character byte ranges, including CP932 aliases and surrogate pairs."""
    decoder=codecs.getincrementaldecoder(codec)(errors='strict')
    text=[];spans=[];start=0
    for index,byte in enumerate(raw):
        out=decoder.decode(bytes([byte]),final=False)
        if out:
            if len(out)!=1:raise ProbeError('ambiguous_codec_character_span')
            text.append(out);spans.append((base+start,base+index+1));start=index+1
    tail=decoder.decode(b'',final=True)
    if tail or start!=len(raw):raise ProbeError('incomplete_codec_character_span')
    return ''.join(text),spans


def ref(data, sha, start, end):
    return dict(source_sha256=sha,offset=start,length=end-start,sha256=digest(data[start:end]))


def split_fields(text,grouping=False):
    """Retain source slices; optional reviewed signed bracket/parenthesis counter.

    The default preserves historical quote-only reports. Grouping is a static
    hypothesis from 0x699fd0, not expression evaluation or a matching-stack rule.
    """
    pieces=[];start=0;quoted=False;depth=0
    for i,char in enumerate(text):
        if char=='"':quoted=not quoted
        elif not quoted:
            if grouping:
                if char in '[(':depth+=1
                elif char in '])':depth-=1
                if abs(depth)>64:raise ProbeError('field_group_depth_limit')
            if char==',' and (not grouping or depth<1):
                pieces.append((start,i));start=i+1
                if len(pieces)>=MAX_FIELDS:raise ProbeError('field_count_limit')
    if quoted:raise ProbeError('unclosed_quote')
    pieces.append((start,len(text)))
    result=[]
    for start,end in pieces:
        value=text[start:end];colon=None;quoted=False
        for index,char in enumerate(value):
            if char=='"':quoted=not quoted
            elif char==':' and not quoted and colon is None:colon=index
        result.append(dict(raw=value,char_start=start,char_end=end,
            key=value[:colon] if colon is not None else None,
            value=(value[colon+1:] if colon is not None else value).replace('"',''),
            quoted='"' in value))
    return result


def line_records(data, filename):
    if len(data)>MAX_TEXT:raise ProbeError('text_size_limit')
    codec,bom,confidence=codec_for(data)
    unit=2 if codec.startswith('utf-16') else 1
    if (len(data)-bom)%unit:raise ProbeError('odd_utf16_length')
    nl='\n'.encode(codec);start=bom;lines=0;sha=digest(data)
    def make(start,end,number):
        raw=data[start:end];text=raw.decode(codec,errors='strict')
        if any(ord(c)<32 and c not in '\r\n\t' for c in text):raise ProbeError('binary_control_bytes')
        return dict(source_file=filename,byte_offset=start,byte_length=end-start,line_number=number,
                    text=text,encoding=codec,encoding_status=confidence,
                    raw_bytes_reference=ref(data,sha,start,end))
    for pos in range(bom,len(data),unit):
        if data[pos:pos+unit]==nl:
            lines+=1
            if lines>MAX_LINES:raise ProbeError('line_limit')
            yield make(start,pos+unit,lines);start=pos+unit
    if start<len(data):
        lines+=1
        if lines>MAX_LINES:raise ProbeError('line_limit')
        yield make(start,len(data),lines)


def lex(data, filename, *, field_model='quote_only'):
    if field_model not in {'quote_only','native_grouping'}:raise ProbeError('unknown_field_split_model')
    codec,bom,enc_confidence=codec_for(data);sha=digest(data)
    records=[];errors=[];blank=None;physical_lines=0
    for line in line_records(data,filename):
        physical_lines=line['line_number'];body=line['text'].rstrip('\r\n')
        if not body.strip():
            if blank:
                blank['byte_length']=line['byte_offset']+line['byte_length']-blank['byte_offset'];blank['line_count']+=1
            else:
                blank=dict(source_file=filename,byte_offset=line['byte_offset'],byte_length=line['byte_length'],
                    line_number=line['line_number'],line_count=1,record_type='empty_span',token=None,operands=[],
                    confidence='verified',unknown_reason=None)
                records.append(blank)
            continue
        blank=None
        text,spans=decode_spans(data[line['byte_offset']:line['byte_offset']+line['byte_length']],codec,line['byte_offset'])
        end=len(text.rstrip('\r\n'));begin=0
        while begin<end and text[begin].isspace():begin+=1
        content=text[begin:end]
        if content.startswith('@@@'):kind='include'
        elif content.startswith('@@'):kind='label'
        elif content.startswith('\\'):kind='command'
        elif content.startswith('^'):kind='line_tag'
        elif content.startswith('//'):kind='comment_candidate'
        elif content.startswith('％'):kind='sound_identifier'
        elif re.match(r'^\$[A-Za-z_][A-Za-z_0-9]*=',content):kind='macro_assignment_candidate'
        elif re.match(r'^[A-Za-z_][A-Za-z_0-9]*=',content):kind='setting_assignment_candidate'
        else:kind='opaque_text'
        fragments=[]
        if kind=='command':
            # Backslashes inside quoted paths never start instructions.
            starts=[];quoted=False
            for i in range(begin,end):
                if text[i]=='"':quoted=not quoted
                elif text[i]=='\\' and not quoted:starts.append(i)
            if quoted:errors.append(dict(category='unclosed_quote',byte_offset=line['byte_offset']))
            for a,b in zip(starts,starts[1:]+[end]):
                while b>a and text[b-1].isspace():b-=1
                if b>a:fragments.append((a,b,'command'))
        else:fragments=[(begin,end,kind)]
        for a,b,kind in fragments:
            value=text[a:b];start=spans[a][0];stop=spans[b-1][1]
            record=dict(source_file=filename,byte_offset=start,byte_length=stop-start,
                line_number=line['line_number'],line_count=1,record_type=kind,token=None,operands=[],
                confidence='inferred' if kind=='command' else 'verified',semantic_status='not_tested',
                unknown_reason='lexical candidate; complete QLIE grammar and execution semantics unverified')
            try:
                if kind in {'command','line_tag'}:
                    model=field_model if kind=='command' else 'quote_only'
                    fields=split_fields(value[1:],grouping=model=='native_grouping');record['token']=fields[0]['value']
                    record['operand_split_model']=model
                    if not re.fullmatch(r'[A-Za-z?][A-Za-z_0-9?]*',record['token'] or ''):
                        record['token_shape_status']='unsupported'
                    for field in fields[1:]:
                        ca=a+1+field['char_start'];cb=a+1+field['char_end']
                        field['byte_offset']=spans[ca][0] if ca<len(spans) else stop
                        field['byte_length']=(spans[cb-1][1]-spans[ca][0]) if ca<cb else 0
                        record['operands'].append(field)
                elif kind in {'include','label','sound_identifier'}:
                    n={'include':3,'label':2,'sound_identifier':1}[kind]
                    record['identifier']=value[n:]
                elif kind.endswith('_assignment_candidate'):
                    record['identifier'],record['rhs']=value.split('=',1)
            except ProbeError as exc:
                record['record_type']='unknown_record';record['unknown_reason']=str(exc)
                errors.append(dict(category=str(exc),byte_offset=start))
            record['raw_bytes_reference']=ref(data,sha,start,stop)
            records.append(record)
            if len(records)>MAX_TOKENS:raise ProbeError('record_limit')
    for r in records:
        if r['record_type']=='empty_span':
            r['raw_bytes_reference']=ref(data,sha,r['byte_offset'],r['byte_offset']+r['byte_length'])
    covered=[];cursor=0
    for record in records:
        if record['byte_offset']>cursor:
            covered.append(dict(source_file=filename,byte_offset=cursor,byte_length=record['byte_offset']-cursor,
                record_type='bom' if cursor==0 and record['byte_offset']==bom and bom else 'layout_span',
                token=None,operands=[],confidence='verified',unknown_reason=None,
                raw_bytes_reference=ref(data,sha,cursor,record['byte_offset'])))
        covered.append(record);cursor=record['byte_offset']+record['byte_length']
    if cursor<len(data):
        covered.append(dict(source_file=filename,byte_offset=cursor,byte_length=len(data)-cursor,
            record_type='bom' if cursor==0 and bom==len(data) else 'layout_span',token=None,operands=[],
            confidence='verified',unknown_reason=None,raw_bytes_reference=ref(data,sha,cursor,len(data))))
    if sum(r['byte_length'] for r in covered)!=len(data):raise ProbeError('byte_coverage_error')
    return dict(source_file=filename,sha256=sha,encoding=codec,encoding_status=enc_confidence,bom_size=bom,
        status='verified' if not errors else 'unsupported',physical_lines=physical_lines,records=covered,errors=errors,
        byte_coverage='verified',execution_semantics='unsupported',
        grammar_profile=dict(status='inferred',field_model=field_model,
            rule='Literal prefixes and backslashes outside quotes; command field splitting is versioned, not complete QLIE grammar'))


def sanitized(record):
    """Metadata projection; commercial text and parameter values never leave private/."""
    keys=['source_file','byte_offset','byte_length','line_number','line_count','record_type','token',
          'confidence','semantic_status','unknown_reason','raw_bytes_reference','token_shape_status']
    result={k:record[k] for k in keys if k in record}
    if result.get('token') and not re.fullmatch(r'[A-Za-z?][A-Za-z_0-9?]*',result['token']):
        result['token_sha256']=digest(result.pop('token').encode())
    result['operands']=[dict(key=f['key'] if f['key'] and re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*',f['key']) else None,
        byte_offset=f['byte_offset'],byte_length=f['byte_length'],quoted=f['quoted'],
        value_sha256=digest(f['value'].encode())) for f in record.get('operands',[])]
    for key in ['identifier','rhs']:
        if key in record:result[key+'_sha256']=digest(record[key].encode())
    return result
