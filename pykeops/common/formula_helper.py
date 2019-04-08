import numpy as np
from pykeops.numpy import Genred as Genred_numpy
from pykeops.numpy.utils import numpytools
try:
    import torch
    from pykeops.torch import Genred as Genred_torch
    from pykeops.torch.utils import torchtools
    usetorch = True
except ImportError:
    usetorch = False
    pass

class keops_formula:
   
    def __init__(self,x=None,axis=None):
        if x is not None:
            if isinstance(x,np.ndarray):
                self.tools = numpytools
                self.Genred = Genred_numpy
            elif usetorch and isinstance(x,torch.Tensor):
                self.tools = torchtools
                self.Genred = Genred_torch
            else:
                raise ValueError("incorrect input")
            if len(x.shape)==3:
                # init as 3d array : shape must be either (N,1,D) or (1,N,D) or (1,1,D)
                if axis is not None:
                    raise ValueError("axis should not be given for 3d array input")
                if x.shape[0]==1:
                    if x.shape[1]==1:
                        x = self.tools.view(x,(x.shape[2]))
                    else:
                        x = self.tools.view(x,(x.shape[1],x.shape[2]))
                        axis = 1
                elif x.shape[1]==1:
                    x = self.tools.view(x,(x.shape[0],x.shape[2]))
                    axis = 0
                else:
                    raise ValueError("incorrect shape for input array")
            if len(x.shape)==2:
                # init as 2d array : shape is (N,D) and axis must be given
                if axis is None:
                    raise ValueError("axis should be given")
                self.variables = (x,)
                self.dim = x.shape[1]
                # id(x) is used as temporary identifier for KeOps "Var", this will be changed when calling method "fixvariables"
                self.formula = "Var(" + str(id(x)) + "," + str(self.dim) + "," + str(axis) + ")"
                self.n = [None,None]
                self.n[axis] = x.shape[0]
                self.dtype = self.tools.dtype(x)
            elif len(x.shape)==1:
                # init as 1d array : x is a parameter
                self.variables = (x,)
                self.dim = x.shape[0]
                self.formula = "Var(" + str(id(x)) + "," + str(self.dim) + ",2)"
                self.dtype = self.tools.dtype(x)
                self.n = [None,None]
            else:
                raise ValueError("input array should be 2d or 3d")
        # N.B. we allow empty init

    def fixvariables(self):
        # we assign indices 0,1,2... id to each variable
        i = 0
        newvars = ()
        for v in self.variables:
            tag = "Var("+str(id(v))
            if tag in self.formula:
                self.formula = self.formula.replace(tag,"Var("+str(i))
                i += 1
                newvars += (v,)
        self.variables = newvars

    def joinvars(self,other):
        # we simply concatenate the two tuples of variables, without worrying about repetitions yet
        variables = self.variables + other.variables
        # now we have to check/update the two values n[0] and n[1]
        n = self.n
        for i in [0,1]:
            if n[i]:
                if other.n[i]:
                    if self.n[i]!=other.n[i]:
                        raise ValueError("incompatible sizes")
            else:
                n[i] = other.n[i]
        return variables, n


    # prototypes for operations
                    
    def unary(self,string,dimres=None,opt_arg=None,opt_arg2=None):
        if not dimres:
            dimres = self.dim
        res = keops_formula()
        res.variables, res.n = self.variables, self.n
        if opt_arg2:
            res.formula = string +"(" + self.formula + "," + str(opt_arg) + "," + str(opt_arg2) + ")"
        elif opt_arg:
            res.formula = string +"(" + self.formula + "," + str(opt_arg) + ")"
        else:
            res.formula = string +"(" + self.formula + ")"
        res.dim = dimres
        res.dtype = self.dtype
        res.tools = self.tools
        res.Genred = self.Genred
        return res        
                        
    def binary(self,other,string1="",string2=",",dimres=None,dimcheck="same"):
        if type(self) == type(keops_formula()):
            other = keops_formula.keopsify(other,self.tools,self.dtype)
        else:
            self = keops_formula.keopsify(self,other.tools,other.dtype)  
        if not dimres:
            dimres = max(self.dim,other.dim)
        res = keops_formula()
        res.dtype = self.dtype    
        if self.tools:
            if other.tools:
                if self.tools != other.tools:
                    raise ValueError("cannot mix numpy and torch arrays")
                else:
                    res.tools = self.tools
                    res.Genred = self.Genred
            else:
                res.tools = self.tools
                res.Genred = self.Genred
        else:
            res.tools = other.tools  
            res.Genred = other.Genred          
        if dimcheck=="same" and self.dim!=other.dim:
            raise ValueError("dimensions must be the same")
        elif dimcheck=="sameor1" and (self.dim!=other.dim and self.dim!=1 and other.dim!=1):
            raise ValueError("incorrect input dimensions")
        res.variables, res.n = self.joinvars(other)
        res.formula = string1 + "(" + self.formula + string2 + other.formula + ")"
        res.dim = dimres
        return res
        
    def keopsify(x,tools,dtype):
        if type(x) != type(keops_formula()):
            if type(x)==float:
                x = keops_formula(tools.array([x],dtype))
            elif type(x)==int:
                x = keops_formula.IntCst(x,dtype)
            else:
                raise ValueError("incorrect input")
        elif x.dtype != dtype:
            raise ValueError("data types are not compatible")
        return x       

    def IntCst(n,dtype):
        res = keops_formula()
        res.dtype = dtype
        res.variables = ()
        res.formula = "IntCst(" + str(n) + ")"
        res.dim = 1
        res.tools = None
        res.Genred = None
        res.n = [None,None]
        return res
    
    # list of operations
    
    def __add__(self,other):
        return self.binary(other,string2="+")

    def __radd__(self,other):
        if other==0:
            return self
        else:
            return keops_formula.binary(other,self,string2="+")
       
    def __sub__(self,other):
        return self.binary(other,string2="-")
        
    def __rsub__(self,other):
        if other==0:
            return -self
        else:
            return keops_formula.binary(other,self,string2="-")
        
    def __mul__(self,other):
        return self.binary(other,string2="*",dimcheck="sameor1")
        
    def __rmul__(self,other):
        if other==0:
            return O
        elif other==1:
            return self
        else:
            return keops_formula.binary(other,self,string2="*",dimcheck="sameor1")
       
    def __truediv__(self,other):
        return self.binary(other,string2="/",dimcheck="sameor1")
        
    def __rtruediv__(self,other):
        if other==0:
            return O
        elif other==1:
            return self.unary("Inv")
        else:
            return keops_formula.binary(other,self,string2="/",dimcheck="sameor1")
       
    def __or__(self,other):
        return self.binary(other,string2="|",dimres=1)
        
    def __ror__(self,other):
        return keops_formula.binary(other,self,string2="|",dimres=1)
        
    def exp(self):
        return self.unary("Exp")
    
    def log(self):
        return self.unary("Log")
    
    def sin(self):
        return self.unary("Sin")
    
    def cos(self):
        return self.unary("Cos")
    
    def __abs__(self):
        return self.unary("Abs")
    
    def abs(self):
        return self.unary("Abs")
    
    def sqrt(self):
        return self.unary("Sqrt")
    
    def rsqrt(self):
        return self.unary("Rsqrt")
    
    def __neg__(self):
        return self.unary("Minus")
    
    def __pow__(self,other):
        if type(other)==int:
            if other==2:
                return self.unary("Square")
            else:
                return self.unary("Pow",opt_arg=other)
        elif type(other)==float:
            if other == .5:
                return self.unary("Sqrt")
            elif other == -.5:
                return self.unary("Rsqrt")
            else:
                other = keops_formula(self.tools.array([other],self.dtype))
        if type(other)==type(keops_formula()):
            if other.dim == 1 or other.dim==self.dim:
                return self.binary(other,string1="Powf",dimcheck="sameor1")
            else:
                raise ValueError("incorrect dimension of exponent")
        else:
            raise ValueError("incorrect input for exponent")

    def power(self,other):
        return self**other
    
    def square(self):
        return self.unary("Square")
    
    def sqrt(self):
        return self.unary("Sqrt")
    
    def rsqrt(self):
        return self.unary("Rsqrt")
    
    def sign(self):
        return self.unary("Sign")
    
    def step(self):
        return self.unary("Step")
    
    def relu(self):
        return self.unary("ReLU")
    
    def sqnorm2(self):
        return self.unary("SqNorm2",dimres=1)
    
    def norm2(self):
        return self.unary("Norm2",dimres=1)
    
    def normalize(self):
        return self.unary("Normalize")
    
    def sqdist(self,other):
        return self.binary(other,string1="SqDist",dimres=1)
    
    def weightedsqnorm(self,other):
        if type(self) != type(keops_formula()):
            self = keops_formula.keopsify(self,other.tools,other.dtype)  
        if self.dim not in (1,other.dim,other.dim**2):
            raise ValueError("incorrect dimension of input for weightedsqnorm")
        return self.binary(other,string1="WeightedSqNorm",dimres=1)
    
    def weightedsqdist(self,f,g):
        return self.weightedsqnorm(f-g)
    
    def elem(self,i):
        if type(i) is not int:
            raise ValueError("input should be integer")
        if i<0 or i>=self.dim:
            raise ValueError("index is out of bounds")
        return self.unary("Elem",dimres=1,opt_arg=i)
    
    def extract(self,i,d):
        if (type(i) is not int) or (type(d) is not int):
            raise ValueError("inputs should be integers")
        if i<0 or i>=self.dim:
            raise ValueError("starting index is out of bounds")
        if d<0 or i+d>=self.dim:
            raise ValueError("dimension is out of bounds")
        return self.unary("Extract",dimres=d,opt_arg=i,opt_arg2=d)
    
    def __getitem__(self, key):
        if not isinstance(key,tuple) or len(key)!=3 or key[0]!=slice(None) or key[1]!=slice(None):
            raise ValueError("only slicing of the forms [:,:,k], [:,:,k:l], [:,:,k:] or [:,:,:l] are allowed")
        key = key[2]
        if isinstance(key,slice):
            if key.step is not None:
                raise ValueError("only slicing of the forms [:,:,k], [:,:,k:l], [:,:,k:] or [:,:,:l] are allowed")
            if key.start is None:
                key.start = 0
            if key.stop is None:
                key.stop = self.dim
            return self.extract(key.start,key.stop-key.start)
        elif isinstance(key,int):
            return self.elem(key)
            
    def concat(self,other):
        return self.binary(other,string1="Concat",dimres=self.dim+other.dim,dimcheck=None)

    def concatenate(self,axis):
        if axis != 2:
            raise ValueError("only concatenation over axis=2 is supported")
        return
        if isinstance(self,tuple):
            if len(self)==0:
                raise ValueError("tuple must not be empty")
            elif len(self)==1:
                return self
            elif len(self)==2:    
                return self[0].concat(self[1])
            else:
                return keops_formula.concatenate(self[0].concat(self[1]),self[2:],axis=2)
        else:
            raise ValueError("input must be tuple")    
    
    def matvecmult(self,other):
        return self.binary(other,string1="MatVecMult",dimres=self.dim//other.dim,dimcheck=None)        
        
    def vecmatmult(self,other):
        return self.binary(other,string1="VecMatMult",dimres=other.dim//self.dim,dimcheck=None)        
        
    def tensorprod(self,other):
        return self.binary(other,string1="TensorProd",dimres=other.dim*self.dim,dimcheck=None)        
                
         
    # prototypes for reductions

    def unaryred(self,reduction_op,opt_arg=None,axis=None, dim=None, **kwargs):
        if axis is None:
            axis = dim
        if axis not in (0,1):
            raise ValueError("axis must be 0 or 1 for reduction")
        self.fixvariables()
        return self.Genred(self.formula, [], reduction_op, axis, self.tools.dtypename(self.dtype), opt_arg)(*self.variables, **kwargs)

    def binaryred(self,other,reduction_op,axis=None,dim=None,opt_arg=None, **kwargs):
        if axis is None:
            axis = dim
        if axis not in (0,1):
            raise ValueError("axis must be 0 or 1 for reduction")
        self.fixvariables() 
        # *** this is incorrect, we should join variables in "other" before using fixvariables ***
        return self.Genred(self.formula, [], reduction_op, axis, self.tools.dtypename(self.dtype), opt_arg, other.formula)(*self.variables, **kwargs)

        
    # list of reductions

    def sum(self,axis=None,dim=None, **kwargs):
        if axis is None:
            axis = dim
        if axis==2:
            return self.unary("Sum",dimres=1)
        else:
            return self.unaryred("Sum", axis=axis, **kwargs)
    

    def logsumexp(self,**kwargs):
        return self.unaryred("LogSumExp", **kwargs)
    
    



# convenient aliases 

def Vi(x):
    return keops_formula(x,0)
    
def Vj(x):
    return keops_formula(x,1)

def Pm(x):
    return keops_formula(x,2)
