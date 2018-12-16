# This script perform an analysis of a formal grammar to check the correctness
# of the hand-written parser and also to help writing it.
# Indeed, as the C grammar is quite complex, it is VERY easy to miss LL(k) conflits


    # Modules

import re
import argparse
import logging

try:
    import colorlog
    handler = colorlog.StreamHandler()
    handler.setFormatter(colorlog.ColoredFormatter('%(log_color)s[%(levelname)s|%(filename)s:%(lineno)s] %(message)s'))
    logging.getLogger().addHandler(handler)
except:
    logging.basicConfig(format='[%(levelname)s|%(filename)s:%(lineno)s] %(message)s') # |%(funcName)s


    # Data structures

# A | B | C
class ExprChoice:
    def __init__(self, lhs, rhs):
        self.lhs = lhs
        self.rhs = rhs
    def __repr__(self):
        safeSet = (ExprOption, ExprRepeat, ExprTerminal, ExprRule, ExprChoice)
        prefix = self.lhs if type(self.lhs) in safeSet else '({0})'.format(self.lhs)
        suffix = self.rhs if type(self.rhs) in safeSet else '({0})'.format(self.rhs)
        return '{0} | {1}'.format(prefix, suffix)

# A B C
class ExprSequence:
    def __init__(self, lhs, rhs):
        self.lhs = lhs
        self.rhs = rhs
    def __repr__(self):
        safeSet = (ExprOption, ExprRepeat, ExprTerminal, ExprRule, ExprSequence)
        prefix = self.lhs if type(self.lhs) in safeSet else '({0})'.format(self.lhs)
        suffix = self.rhs if type(self.rhs) in safeSet else '({0})'.format(self.rhs)
        return '{0} {1}'.format(prefix, suffix)

# A?
class ExprOption:
    def __init__(self, subExpr):
        self.content = subExpr
    def __repr__(self):
        if type(self.content) in (ExprOption, ExprRepeat, ExprTerminal, ExprRule):
            return '{0}?'.format(self.content)
        return '({0})?'.format(self.content)

# A+
class ExprRepeat:
    def __init__(self, subExpr):
        self.content = subExpr
    def __repr__(self):
        if type(self.content) in (ExprOption, ExprRepeat, ExprTerminal, ExprRule):
            return '{0}+'.format(self.content)
        return '({0})+'.format(self.content)

# WHILE, OP_PLUS...
class ExprTerminal:
    def __init__(self, value):
        self.value = value
    def __repr__(self):
        return '{0}'.format(self.value)

# function, statement...
class ExprRule:
    def __init__(self, value):
        self.value = value
    def __repr__(self):
        return '{0}'.format(self.value)

class Rule:
    def __init__(self, name, value):
        self.name = name
        self.value = value
    def __repr__(self):
        return '{0}: {1}'.format(self.name, self.value)


    # Read grammar from a file

def getRulesFromFile(filename):
    with open('formal-llk-grammar') as f:
        rules = []
        buff = ''
        for line in f:
            commentPos = line.find('//')
            if commentPos >= 0:
                line = line[:commentPos]
            line = line.strip()
            if len(line) > 0:
                buff = '{0} {1}'.format(buff, line)
                if line.endswith(';'):
                    rules.append(buff[:-1].strip())
                    buff = ''
        return rules


    # Grammar lexer

def tokenize(ruleName, rule):
    tokens = []
    rule = rule.strip()
    while len(rule) > 0:
        res = re.findall(r'^([a-zA-Z_][a-zA-Z_0-9]*|\(|\)|\||\*|\+|\?)', rule)
        errMsg = 'Syntax error in rule %s: bad token' % ruleName
        assert len(res) == 1, errMsg
        token = res[0]
        tokens.append(token)
        rule = rule[len(token):].strip()
    return tokens


    # Grammar parser

def parseChoice(tokens):
    (lhs, tokens) = parseSequence(tokens)
    if len(tokens) == 0 or tokens[0] != '|':
        return (lhs, tokens)
    (rhs, tokens) = parseChoice(tokens[1:])
    return (ExprChoice(lhs, rhs), tokens)

def parseSequence(tokens):
    (lhs, tokens) = parseCard(tokens)
    if len(tokens) == 0 or not re.match(r'^(?:[a-zA-Z_][a-zA-Z_0-9]*|\()$', tokens[0]):
        return (lhs, tokens)
    (rhs, tokens) = parseSequence(tokens)
    return (ExprSequence(lhs, rhs), tokens)

def parseCard(tokens):
    (rule, tokens) = parseTerm(tokens)
    while len(tokens) != 0 and tokens[0] in '?+*':
        if tokens[0] == '?':
            rule = ExprOption(rule)
        elif tokens[0] == '+':
            rule = ExprRepeat(rule)
        elif tokens[0] == '*':
            rule = ExprOption(ExprRepeat(rule))
        else:
            assert False
        tokens = tokens[1:]
    return (rule, tokens)

def parseTerm(tokens):
    if tokens[0] == '(':
        (rule, tokens) = parseChoice(tokens[1:])
        assert len(tokens) > 0 and tokens[0] == ')'
        return (rule, tokens[1:])
    token = tokens[0]
    assert token not in '?+*()'
    if token.upper() == token:
        return (ExprTerminal(token), tokens[1:])
    return (ExprRule(token), tokens[1:])

def parseRule(rule):
    tmp = re.findall(r'^([a-zA-Z_][a-zA-Z_0-9]*) *= *([^=]+)$', rule)
    assert len(tmp) == 1
    lhs, rhs = tmp[0]
    tokens = tokenize(lhs, rhs)
    rhs, tokens = parseChoice(tokens)
    errMsg = 'Syntax error in rule {0}: unable to parse remaining tokens {1}'.format(lhs, tokens)
    assert len(tokens) == 0, errMsg
    return Rule(name=lhs, value=rhs)


    # Algorithms to find non-trivial properties of the grammar

# Algorithm to check if the grammar is LL(k) and say why if not (k is the number of lookahead tokens)
# Perform an over-approximation in practice (but not certified to work): may produce false-positive
# Horrible exponential implementation (but the state-of-the-art is not better in term of complexity...)
# Assume no conflit with epsilon transitions
# Can fail to detect conflits with recursion such as the if-else conflict
# Complex cases:
#     - A* B A* B? A*  should generate all combinaisons (for K=3: ABB BAB BBA AAB BAA ABA)
#     - same thing for  A? B? C? D+  or  (A B) (C D) (E F)
#     - those rules can be split in multiple rules
#     - conflict can occurs at the end of the sequence or even in sub-expressions: A B (C? A | A B)
def find_llk_conflits(ruleName, rule, grammar, k, trace=None, requiredK=None):
    def makeError(ruleName, rule1, rule2, conflits):
        maxTokens = 3
        if len(conflits) > maxTokens:
            remaining = len(conflits) - maxTokens
            errMsgBase = 'LL({4}) conflits in rule {0}: `{1}` and `{2}` share {3}... (%s more)' % remaining
        else:
            errMsgBase = 'LL({4}) conflits in rule {0}: `{1}` and `{2}` share {3}'
        sharedTerms = ', '.join('>'.join(e) for e in list(conflits)[:maxTokens])
        errMsg = errMsgBase.format(ruleName, rule1, rule2, sharedTerms, k)
        return errMsg
    def truncateAndMerge(termStringSet, limit):
        return {e[:limit] for e in termStringSet}
    def findDuplicates(lst):
        seen = set()
        duplicates = set()
        for e in lst:
            if e in seen:
                duplicates.add(e)
            seen.add(e)
        return duplicates
    if trace is None:
        trace = []
    if requiredK is None:
        requiredK = k
    assert requiredK > 0, 'programming error'
    if isinstance(rule, Rule):
        trace = trace + [rule.name]
        errMsg = 'Not an LL(k) grammar: cyclic rule dependencies ({0})'.format(' -> '.join(trace))
        assert trace[:-1].count(rule.name) < k, errMsg
        return find_llk_conflits(ruleName, rule.value, grammar, k, trace, requiredK)
    elif isinstance(rule, ExprChoice):
        lhsTerms = find_llk_conflits(ruleName, rule.lhs, grammar, k, trace[:], requiredK)
        rhsTerms = find_llk_conflits(ruleName, rule.rhs, grammar, k, trace, requiredK)
        # WARNING: much more complex if there is smaller-than-k elems in terms
        conflits = lhsTerms & rhsTerms
        if len(conflits) > 0 and requiredK == k and len(trace) == 0:
            logging.error(makeError(ruleName, rule.lhs, rule.rhs, conflits))
        return lhsTerms | rhsTerms
    elif isinstance(rule, ExprSequence):
        terms = find_llk_conflits(ruleName, rule.lhs, grammar, k, trace, requiredK)
        smallestLen = min(len(e) for e in terms)
        if smallestLen < requiredK:
            # Append rhs for too small tuples in terms
            suffixes = find_llk_conflits(ruleName, rule.rhs, grammar, k, trace, requiredK-smallestLen)
            paddedTerms = [e+s for e in terms for s in truncateAndMerge(suffixes, requiredK-len(e))]
            terms = set(paddedTerms)
            conflits = findDuplicates(paddedTerms)
            # Empty should not be a problem...
            if () in conflits:
                conflits.remove(())
            # Check for self-conflicts (eg: `(A* B) | B`, or just `A* A`)
            if len(conflits) > 0 and requiredK == k and len(trace) == 0:
                logging.error(makeError(ruleName, rule.lhs, rule.rhs, conflits))
        return terms
    elif isinstance(rule, ExprRepeat):
        # Possible optimization: break the loop if all terms are >= requiredK
        allTerms = []
        for i in range(requiredK):
            terms = find_llk_conflits(ruleName, rule.content, grammar, k, trace, requiredK)
            allTerms += [e[:requiredK] for e in terms]
        # WARNING: TODO !!!
        #sortedTerms = sorted(terms)
        #print([sortedTerms[i] for i in range(len(sortedTerms)-1) if sortedTerms[i]==sortedTerms[i+1]])
        #assert(len(terms) == len(set(terms))) # Self-conflicts (eg: A* B with B), no sure this is a problem...
        return set(allTerms)
    elif isinstance(rule, ExprOption):
        terms = find_llk_conflits(ruleName, rule.content, grammar, k, trace, requiredK)
        terms.add(())
        return terms
    elif isinstance(rule, ExprTerminal):
        return {(rule.value,)}
    elif isinstance(rule, ExprRule):
        return find_llk_conflits(ruleName, grammar[rule.value], grammar, k, trace, requiredK)
    assert False, 'Unknown ruleType (%s)' % ruleType

def iterate_over_subexpr(ruleName, expr, grammar, k, subChoice=False):
    assert not isinstance(expr, Rule)
    if isinstance(expr, ExprChoice):
        # Recursion should not be necessary here as find_llk_conflits already do it with the same k
        iterate_over_subexpr(ruleName, expr.lhs, grammar, k, True)
        iterate_over_subexpr(ruleName, expr.rhs, grammar, k, True)
        return find_llk_conflits(ruleName, expr, grammar, k)
    elif isinstance(expr, ExprSequence):
        # Check the whole expression using a sliding window
        iterate_over_subexpr(ruleName, expr.lhs, grammar, k)
        iterate_over_subexpr(ruleName, expr.rhs, grammar, k)
        #print('  [%s] Checking:' % ruleName, expr)
        return find_llk_conflits(ruleName, expr, grammar, k)
    elif isinstance(expr, ExprRepeat):
        #print('  [%s] Checking:' % ruleName, expr)
        return find_llk_conflits(ruleName, expr, grammar, k)
    elif isinstance(expr, ExprOption):
        #print('  [%s] Checking:' % ruleName, expr)
        return find_llk_conflits(ruleName, expr, grammar, k)
    else:
        assert isinstance(expr, ExprTerminal) or isinstance(expr, ExprRule)
        return find_llk_conflits(ruleName, expr, grammar, k)

def findall_llk_conflits(grammar, k):
    assert k > 0, 'k=0 not supported' # LL(0) does not provide any choice as tokens cannot be retrieved

    terms = {}
    for rule in grammar.values():
        #if rule.name == 'parameterTypeList':
        terms[rule.name] = iterate_over_subexpr(rule.name, rule.value, grammar, k)

    logging.info('First(k) tokens table for each rule:')
    for ruleName, ruleTerms in terms.items():
        logging.info('    {0}: {1}'.format(ruleName, ', '.join('>'.join(e) for e in ruleTerms)))


    # Main

def main():
    # Args parsing
    cmdParser = argparse.ArgumentParser(
        description='Check if a formal grammar is LL(k) for a given k', 
        formatter_class=argparse.RawTextHelpFormatter
    )
    cmdParser.add_argument('-i', '--input', required=False, dest='inputFile', help='grammar input file to be checked', default='formal-llk-grammar')
    cmdParser.add_argument('-v', '--verbosity', dest='verbosity', help='set the verbosity level\n(0: errors, 1: warnings (default), 2: infos, 3:debug)', type=int, choices=[0, 1, 2, 3], default=1)
    cmdParser.add_argument('-k', '--llk', dest='k', help='number of lookahead tokens allowed during the checks', type=int, choices=[1, 2, 3, 4, 5], default=2)
    cmdArgs = cmdParser.parse_args()

    verbosityLevels = {0: logging.ERROR, 1: logging.WARNING, 2: logging.INFO, 3: logging.DEBUG}
    logging.getLogger().setLevel(verbosityLevels[cmdArgs.verbosity])

    print('Reading file "%s"...' % cmdArgs.inputFile)
    rules = getRulesFromFile(cmdArgs.inputFile)

    #rules =  [
    #    'a = b | c',
    #    'b = c B',
    #    'c = E? d',
    #    'd = D? B a'
    #]

    print('Parsing file "%s"...' % cmdArgs.inputFile)
    grammar = [parseRule(rule) for rule in rules]
    grammar = {rule.name: rule for rule in grammar}
    logging.debug('Parsed rules:')
    for rule in grammar.values():
        logging.debug('    %s' % repr(rule))

    print('Checking if the grammar is LL(%d)...' % cmdArgs.k)
    findall_llk_conflits(grammar, cmdArgs.k)


main()
