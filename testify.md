# stretchr/testify

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
现在分析的testify是v1.6.1版本的,http包已经弃用.那就分析断言和mock包.

## stretchr/testify/assert包分析

先看doc.go,这个文件提供了包的描述和基本使用方法.

assert包的目的:在Go test中提供了很多测试工具.
标准Go test中会有一个判断,用以判断测试是否通过,
assert就是可以简化这一步判断的写法.

    func TestString(t *testing.T){
      var a string = "abc"
      var b string = "abc"

      assert.Equal(t,a,b,"the two words should be the same")
    }

这种写法可以简化很多,看doc.go的描述,还可以依据t创建一个断言对象,
通过断言对象来做断言.这个写法就和标准库类似,后面会重点分析.

断言包assert里面使用了go generate命令,是个非常厉害的工具,可以扩展很多写法,
我么先来看看这部分内容.

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
