import sys
with open('StemSync Packager.pyw', 'r', encoding='utf-8') as f:
    code = f.read()

code = code.split('if __name__ ==')[0]

with open('test_run.py', 'w', encoding='utf-8') as f:
    f.write(code)
    f.write('\n\nimport asyncio, traceback\n')
    f.write('try:\n')
    f.write('    create_bandtrack_zip("Ufaq", "E:/AI Instrument seperator/Ufaq_test", "E:/AI Instrument seperator", manual_artist="Anand Bhaskar")\n')
    f.write('    print("SUCCESS")\n')
    f.write('except Exception as e:\n')
    f.write('    traceback.print_exc()\n')

