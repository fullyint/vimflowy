TestCase = require '../testcase.coffee'

describe 'backspace', () ->
  it "works in simple case", () ->
    t = new TestCase ['abc']
    t.sendKey 'A'
    t.sendKey 'backspace'
    t.sendKey 'backspace'
    t.expect ['a']

  it "works deleting from second line", () ->
    t = new TestCase ['abc', 'def']
    t.sendKeys 'jli'
    t.sendKey 'backspace'
    t.expect ['abc', 'ef']
    t.sendKey 'backspace'
    t.expect ['abcef']
    t.sendKey 'backspace'
    t.expect ['abef']
    t.sendKey 'backspace'
    t.expect ['aef']
    t.sendKey 'backspace'
    t.expect ['ef']
    t.sendKey 'backspace'
    t.expect ['ef']
    t.sendKey 'esc'
    t.sendKey 'u'
    t.expect ['abc', 'def']

  it "works at end of line", () ->
    t = new TestCase ['ab', 'cd']
    t.sendKeys 'jA'
    t.sendKey 'backspace'
    t.sendKey 'backspace'
    t.expect ['ab', '']
    t.sendKey 'backspace'
    t.expect ['ab']
    t.sendKey 'backspace'
    t.expect ['a']

  it "works from children", () ->
    t = new TestCase [
      { text: 'ab', children: [
        'bc'
      ] },
      { text: 'cd', children: [
        'de'
      ] }
    ]
    t.sendKeys 'jji'
    t.sendKey 'backspace'
    # did nothing due to child of 'ab'
    t.expect [
      { text: 'ab', children: [
        'bc'
      ] },
      { text: 'cd', children: [
        'de'
      ] }
    ]
    t.sendKey 'esc'
    t.sendKeys 'kddj'
    t.expect [
      'ab',
      { text: 'cd', children: [
        'de'
      ] }
    ]
    t.sendKeys 'i'
    t.sendKey 'backspace'
    t.expect [
      { text: 'abcd', children: [
        'de'
      ] },
    ]
    t.sendKey 'backspace'
    t.sendKey 'backspace'
    t.sendKey 'backspace'
    t.expect [
      { text: 'cd', children: [
        'de'
      ] },
    ]
    t.sendKey 'backspace'
    t.expect [
      { text: 'cd', children: [
        'de'
      ] },
    ]

  it "works with undo/redo", () ->
    t = new TestCase [
      { text: 'ab', children: [
        'cd'
      ] }
    ]
    t.sendKeys 'ji'
    t.sendKey 'backspace'
    t.expect [
      'abcd'
    ]
    # t.sendKey 'backspace'
    # t.expect [
    #   'acd'
    # ]
    t.sendKey 'esc'
    t.sendKeys 'u'
    t.expect [
      { text: 'ab', children: [
        'cd'
      ] }
    ]
    t.sendKey 'ctrl+r'
    t.expect [
      'abcd'
    ]
    t.sendKey 'x'
    t.expect [
      'acd'
    ]

  it "fails when both rows have children", () ->
    t = new TestCase [
      { text: 'ab', children: [
        'cd'
      ] }
      { text: 'ab', children: [
        'cd'
      ] }
    ]
    t.sendKeys 'jji'
    t.sendKey 'backspace'
    t.expect [
      { text: 'ab', children: [
        'cd'
      ] }
      { text: 'ab', children: [
        'cd'
      ] }
    ]
    t.sendKey 'esc'
    t.sendKeys 'kdd'
    t.expect [
      'ab'
      { text: 'ab', children: [
        'cd'
      ] }
    ]
    t.sendKeys 'ji'
    t.sendKey 'backspace'
    t.expect [
      { text: 'abab', children: [
        'cd'
      ] }
    ]
    t.sendKey 'backspace'
    t.expect [
      { text: 'aab', children: [
        'cd'
      ] }
    ]
    t.sendKey 'esc'
    t.sendKeys 'u'
    t.expect [
      'ab'
      { text: 'ab', children: [
        'cd'
      ] }
    ]


describe 'delete', () ->
  it "works in basic case", () ->
    t = new TestCase ['ab', 'cd']
    t.sendKeys 'i'
    t.sendKey 'delete'
    t.expect ['b', 'cd']
    t.sendKey 'delete'
    t.expect ['', 'cd']
    # doesn't do anything, for now
    t.sendKey 'delete'
    t.expect ['', 'cd']
    t.sendKey 'esc'
    t.sendKey 'u'
    t.expect ['ab', 'cd']

