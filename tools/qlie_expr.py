"""Bounded structural expression hypotheses. No evaluation or side effects."""
import hashlib
import re

# Observed ordered token-reduction passes, not C/Python operator precedence.
GROUPS=[['*','/','%'],['+','-'],['<<','>>'],['^','&','|'],
        ['==','!=','<=','>=','>','<'],['&&','||'],['=']]
BINDING={op:10*(len(GROUPS)-i) for i,group in enumerate(GROUPS) for op in group}
OPS=sorted(list(BINDING)+['++','--'],key=lambda x:(-len(x),x))
# Dollar-prefixed candidates require a complete word; $Background is a name,
# rather than a partially consumed hexadecimal prefix. No literal is evaluated.
NUMBER=re.compile(r'(?:\$[0-9A-Fa-f]+(?!\w)|0[xX][0-9A-Fa-f]+|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)')
NAME=re.compile(r'[#@$]?(?:[^\W\d]|_)\w*(?:\.(?:[^\W\d]|_)\w*)*',re.UNICODE)


class ExpressionError(ValueError):
    def __init__(self,reason,offset=0):super().__init__(reason);self.reason=reason;self.offset=offset


def tokens(text):
    if len(text)>8192:raise ExpressionError('expression_character_limit')
    out=[];i=0
    while i<len(text):
        if text[i].isspace():i+=1;continue
        start=i
        if text[i]=='"':
            i=text.find('"',i+1)
            if i<0:raise ExpressionError('unclosed_string',start)
            i+=1;kind='string_literal_candidate'
        elif text[i] in '()[]':i+=1;kind=text[start:i]
        else:
            match=next((op for op in OPS if text.startswith(op,i)),None)
            if match is not None:i+=len(match);kind='operator'
            else:
                found=NUMBER.match(text,i)
                if found:kind='number_literal_candidate'
                else:found=NAME.match(text,i);kind='identifier_candidate'
                if found is None:raise ExpressionError('unknown_expression_character',i)
                i=found.end()
        out.append(dict(kind=kind,text=text[start:i],start=start,end=i))
        if len(out)>1024:raise ExpressionError('expression_token_limit',start)
    out.append(dict(kind='EOF',text='',start=len(text),end=len(text)))
    return out


class Parser:
    def __init__(self,text):self.stream=tokens(text);self.index=0;self.nodes=0
    def peek(self):return self.stream[self.index]
    def take(self):t=self.peek();self.index+=1;return t
    def need(self,kind):
        if self.peek()['kind']!=kind:raise ExpressionError('missing_'+kind,self.peek()['start'])
        return self.take()
    def node(self,kind,start,end,children=None,**fields):
        self.nodes+=1;children=children or [];depth=1+max((c['depth'] for c in children),default=0)
        if self.nodes>2048:raise ExpressionError('expression_node_limit',start)
        if depth>64:raise ExpressionError('expression_tree_depth_limit',start)
        return dict(kind=kind,start=start,end=end,children=children,depth=depth,confidence='inferred',
                    semantic_status='not_tested',**fields)
    def expression(self,minimum=0,depth=0):
        if depth>64:raise ExpressionError('expression_parse_depth_limit',self.peek()['start'])
        t=self.take()
        if t['kind'] in {'string_literal_candidate','number_literal_candidate','identifier_candidate'}:
            left=self.node(t['kind'],t['start'],t['end'],value=t['text'])
        elif t['kind']=='(':
            inner=self.expression(0,depth+1);end=self.need(')')
            left=self.node('group_candidate',t['start'],end['end'],[inner])
        elif t['kind']=='operator' and t['text'] in {'+','-','^'}:
            child=self.expression(80,depth+1)
            left=self.node('unary_candidate',t['start'],child['end'],[child],operator=t['text'])
        else:raise ExpressionError('missing_or_unverified_prefix_operand',t['start'])
        while True:
            t=self.peek()
            if t['kind']=='[':
                self.take();index=self.expression(0,depth+1);end=self.need(']')
                left=self.node('index_candidate',left['start'],end['end'],[left,index]);continue
            if t['kind']=='(':
                raise ExpressionError('function_call_syntax_not_verified',t['start'])
            if t['kind']=='operator' and t['text'] in {'++','--'}:
                self.take();left=self.node('postfix_update_candidate',left['start'],t['end'],[left],operator=t['text'],
                    unknown_reason='Update side-effect timing, lvalue rules and type coercion unverified');continue
            if t['kind']!='operator' or t['text'] not in BINDING or BINDING[t['text']]<minimum:break
            self.take();right=self.expression(BINDING[t['text']]+1,depth+1)
            left=self.node('binary_candidate',left['start'],right['end'],[left,right],operator=t['text'])
        return left
    def parse(self):
        root=self.expression()
        if self.peek()['kind']!='EOF':raise ExpressionError('unexpected_expression_tail',self.peek()['start'])
        return root


def parse(text):return Parser(text).parse()


def attach_source(node,data,spans,source_file,source_sha256):
    start=node['start'];end=node['end']
    if start<0 or end<=start or end>len(spans):raise ExpressionError('node_span_outside_source',start)
    a=spans[start][0];b=spans[end-1][1]
    node.update(source_file=source_file,source_sha256=source_sha256,byte_offset=a,byte_length=b-a,
        raw_bytes_reference=dict(offset=a,length=b-a,sha256=hashlib.sha256(data[a:b]).hexdigest()))
    for child in node['children']:attach_source(child,data,spans,source_file,source_sha256)
    return node


def public_tree(node):
    out={k:v for k,v in node.items() if k not in {'value','children'}}
    if 'value' in node:out['decoded_atom_sha256']=hashlib.sha256(node['value'].encode()).hexdigest()
    out['children']=[public_tree(c) for c in node['children']]
    return out
