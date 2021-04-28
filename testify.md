# stretchr/testify

这是一个广泛使用的测试库,提供了断言和mock.
这个提供了测试的mock和断言.

这个库使用非常广泛,有机会来刷源码,非常激动.

## 库依赖分析

下面是依赖关系:

- davecgh/go-spew 调试时,结构体打印美化
- pmezard/go-difflib 调试时,对上下文的统一和差异
- stretchr/objx 对数据对象的处理,eg:map/slice/json等
- yaml 支持yaml格式的解析

## 初步分析

这是一个集合库,通过doc.go来引入assert/http/mock库的初始化,
现在分析的testify是v1.6.1版本的,http包已经弃用.其中还有一个require包.

## stretchr/testify/assert包分析

先看doc.go,这个文件提供了包的描述和基本使用方法.

assert包的目的:在Go test中提供了很多测试工具.
标准Go test中会有一个判断,用以判断测试是否通过,
assert就是可以简化这一步判断的写法.

```Golang
func TestString(t *testing.T){
  var a string = "abc"
  var b string = "abc"

  assert.Equal(t,a,b,"the two words should be the same")
}
```

这种写法可以简化很多,看doc.go的描述,还可以依据t创建一个断言对象,
通过断言对象来做断言.这个写法就和标准库类似,后面会重点分析.

断言包assert里面使用了go generate命令,是个非常厉害的工具,可以扩展很多写法,
我么先来看看这部分内容.

```bash
# //go:generate sh -c "cd ../_codegen && go build && cd - && ../_codegen/_codegen -output-package=assert -template=assertion_format.go.tmpl"

# 执行的命令如下:
cd ../_codegen
go build
cd - 
../_codegen/_codegen -output-package=assert -template=assertion_format.go.tmpl
```

整个意思是先生成codegen程序,之后执行程序,完成一些逻辑.

### codegen部分

就一个main.go文件,300多行,先分析.

看描述是:自动读取assert包中的所有断言函数,自动生成相关的requires/forwarded断言.
这是哪两种断言,还不清楚,后面会分析.

看依赖,依赖了大量标准库的包,直接的外部依赖只有一个.

命令行参数有5个:

- pkg, assert包的路径
- includeF, 是否包含格式化函数
- outputPkg, 指定生成代码的归属包名
- tmpFile, 函数模板文件
- out, 指定生成代码的文件名

代码结构分析:

    func main() {
      flag.Parse()

      scope, docs, err := parsePackageSource(*pkg)
      if err != nil {
        log.Fatal(err)
      }

      importer, funcs, err := analyzeCode(scope, docs)
      if err != nil {
        log.Fatal(err)
      }

      if err := generateCode(importer, funcs); err != nil {
        log.Fatal(err)
      }
    }

整个main函数非常简洁地指出了3个操作:解析断言包/分析/生成代码.
下面是函数调用关系:

- parsePackageSource
- analyzeCode
- generateCode
  - parseTemplates
  - outputFile

另外还有一个testFunc的struct,作为analyzeCode的输出,作为generateCode的输入.

未进行源码分析的包,基础了解:

- go/build
  - 读取Go包中的信息
  - 这个包定义了3个术语
    - go path,包含源代码的目录树
      - 用于解决标准go目录树找到不import包的问题
      - 默认path是GOPATH环境变量,目录树包含以下3个目录
      - src,里面存放的源码,src的子目录是包名或可执行名
      - pkg,里面存放的是安装对象,子目录是os_arch的组合
        - 如果src里还包含其他子包,同样会放在pkg里面
        - 可能是.a文件,或者gccgo的libxxx.a文件
      - bin,里面存放的是编译命令
    - 第二个术语叫构建约束,也叫build tag
      - // +build表示编译, // !build 表示忽略
      - 这个可以区分不同的平台,或针对集成测试等等
    - 第三个术语是binary-only,不过1.13之后就不支持了,就不多说了

大致翻了一下codegen,里面大量使用了Go源码解析的包,也就是Go源码编译和AST相关的包,
这块可以单独作为一个部分来分析.从assert包使用go generate来分析一下:

- 有两个解析的模版文件tmpl,通过Go源码分析,重新生成了符合模版的代码
- format模版,为assertions.go源码下的所有函数生成了一个新函数
  - 新函数只添加了一个逻辑:如果实现了tHelper接口,就调用Helper函数
- forward模版,将assertions.go源码下的所有函数提供了一个统一的访问入口Assertions类型

总的来说,go generate下的codegen,是利用Go词法分析+替换的方式来减少人工作业.

### assert包分析

```Golang
func ObjectsAreEqual(expected, actual interface{}) bool {
	if expected == nil || actual == nil {
		return expected == actual
	}

	exp, ok := expected.([]byte)
	if !ok {
		return reflect.DeepEqual(expected, actual)
	}

	act, ok := actual.([]byte)
	if !ok {
		return false
	}
	if exp == nil || act == nil {
		return exp == nil && act == nil
	}
	return bytes.Equal(exp, act)
}
```

这是帮助函数,其实可以等同于v1.16的reflect.DeepEqual(),
bytes.Equqal()就是将[]byte转为string再做Go的==比较.
猜测这种reflect.DeepEqual()之后再对[]byte做比较,是为了兼容老的Go版本.

这个对象比较是通过反射包来比较,特点是类型不同,则不想等,其他规则如下:

1. 不同类型的值是不相等的
2. 数组,元素相等
3. 结构体,字段相等(包括暴露和非暴露的)
4. 函数,都为nil(其他情况则不相等)
5. 接口,具体值相等
6. map,条件1:都是nil或都不是nil,条件2:长度相同,key和value相等
7. 指针,要么用Go的==判断相等;要么指向的值相等
8. slice,都是nil或都不是nil;长度相同;底层数组是同一个或x和y的元素是相同的
9. 数值/bool/字符串/通道,用Go的==判断相等

```Golang
func ObjectsAreEqualValues(expected, actual interface{}) bool {
	if ObjectsAreEqual(expected, actual) {
		return true
	}

	actualType := reflect.TypeOf(actual)
	if actualType == nil {
		return false
	}
	expectedValue := reflect.ValueOf(expected)
	if expectedValue.IsValid() && expectedValue.Type().ConvertibleTo(actualType) {
		// Attempt comparison after type conversion
		return reflect.DeepEqual(expectedValue.Convert(actualType).Interface(), actual)
	}

	return false
}
```

第二个帮助函数,除了比较对象,还比较不同类型的值,算是扩展了一下.