import json, sys, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from application_catalog import parse_applications,sync_applications
class CatalogTest(unittest.TestCase):
 def test_names_and_validation(self):
  item={'bundleName':'com.example.browser','label':'浏览器 🎮'}
  self.assertEqual(parse_applications(json.dumps([item,item])),[item])
  for bad in [None,{},[{'bundleName':'bad;cmd','label':'bad'}],[{'bundleName':'com.example.app','label':'bad\n'}]]:
   with self.assertRaises((RuntimeError,AttributeError)):parse_applications(json.dumps(bad))
 def test_no_enumeration_without_request(self):
  class H:
   def run(self,*a):pass
   def shell(self,*a):raise AssertionError('must not enumerate')
  with patch('application_catalog.ForwardedControl') as control:
   control.return_value.__enter__.return_value.request.return_value=(200,{'request':0})
   self.assertIsNone(sync_applications(H(),'serial','token','127.0.0.1'))

class RequestLifecycleTest(unittest.TestCase):
 def test_expired_request_does_not_enumerate(self):
  class H:
   def run(self,*a):pass
   def shell(self,*a):raise AssertionError('must not enumerate expired request')
  with patch('application_catalog.ForwardedControl') as control:
   control.return_value.__enter__.return_value.request.return_value=(200,{'request':1})
   with self.assertRaisesRegex(RuntimeError,'Invalid application catalog request'):
    sync_applications(H(),'serial','token','127.0.0.1')
 def test_failure_is_reported_without_raw_output(self):
  import time
  from unittest.mock import Mock
  h=Mock();h.shell.return_value='unsupported command, sensitive details'
  request=int(time.time()*1000)
  with patch('application_catalog.ForwardedControl') as control:
   c=control.return_value.__enter__.return_value
   c.request.return_value=(200,{'request':request})
   with self.assertRaisesRegex(RuntimeError,'supported application list'):
    sync_applications(h,'serial','token','127.0.0.1')
   self.assertEqual(c.request.call_args.args,('POST','/v1/applications',{'request':request,'applications':[],'error':'unsupported'}))
 def test_success_only_publishes_requested_names(self):
  import time
  from unittest.mock import Mock
  h=Mock();h.shell.return_value='[{"bundleName":"com.example.app","label":"Example"}]'
  request=int(time.time()*1000)
  with patch('application_catalog.ForwardedControl') as control:
   c=control.return_value.__enter__.return_value
   c.request.return_value=(200,{'request':request})
   self.assertEqual(sync_applications(h,'serial','token','127.0.0.1'),1)
   h.shell.assert_called_once_with('bm','dump','-a','-l')
   self.assertEqual(c.request.call_args.args[2]['request'],request)

if __name__=='__main__':unittest.main()
